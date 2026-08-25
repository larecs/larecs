"""Minimal GPU-backed sketch of the systems API.

This is intentionally not the ECS storage implementation yet. It demonstrates
the first execution boundary: a filtered system run owns device-resident SoA
component columns, launches a Mojo GPU kernel, and copies results back only for
verification.
"""

from max.gpu.host import DeviceBuffer, DeviceContext, DevicePointer, HostBuffer
from std.builtin.device_passable import DevicePassable, DeviceTypeEncoder
from std.gpu import global_idx
from std.math import ceildiv
from std.memory import (
    Layout,
    ThinAllocation,
    alloc,
    dealloc,
    unsafe_uninit_copy_n,
    unsafe_uninit_move_n,
    unsafe_destroy_n,
)
from std.sys import has_accelerator, size_of

from larecs.component import ComponentType, ComponentManager
from larecs.unsafe_box import UnsafeBox

from tracy import Zone, frame_mark


@fieldwise_init
struct Position(Copyable):
    var x: Float32
    var y: Float32


@fieldwise_init
struct Velocity(Copyable):
    var dx: Float32
    var dy: Float32


@fieldwise_init
struct Name(Copyable):
    var name: String


comptime DEFAULT_CAPACITY = 32
comptime entity_count = 256
comptime block_size = 128
comptime block_count = ceildiv(entity_count, block_size)

# The kernel body is independent of the execution backend. The backend adapter
# below is responsible for constructing the matching context and launching it.
comptime run_on_gpu = True


@fieldwise_init
struct Components[*ComponentTypes: ComponentType]:
    pass


@fieldwise_init
struct Filter[
    _include: Components = Components[](), _exclude: Components = Components[]()
]:
    comptime include[*ComponentTypes: ComponentType] = Filter[
        Components[
            *TypeList._concat[
                Self._include.ComponentTypes.values, ComponentTypes.values
            ]()
        ](),
        Self._exclude,
    ]
    comptime exclude[*ComponentTypes: ComponentType] = Filter[
        Self._include,
        Components[
            *TypeList._concat[
                Self._exclude.ComponentTypes.values, ComponentTypes.values
            ]()
        ](),
    ]


struct _ComponentColumn(Boolable, Copyable, Deinitable, Movable):
    """Owns one type-erased component column allocation.

    The allocation is erased only while it is stored. Lifecycle operations keep
    the concrete component type through callbacks installed by the constructor.
    """

    comptime Data = Optional[ThinAllocation[Byte]]
    """Type-erased optional allocation used to store component data."""

    var _data: Self.Data
    """The allocation containing the column's component values."""
    var _destroy: def(
        var allocation: ThinAllocation[Byte], length: Int, capacity: Int
    ) thin
    """Callback that destroys initialized values and frees a column allocation."""
    var _copy: def(
        data: Self.Data, length: Int, capacity: Int
    ) thin -> Self.Data
    """Callback that copies initialized values into a new allocation."""
    var _resize: def(
        mut data: Self.Data,
        length: Int,
        old_capacity: Int,
        new_capacity: Int,
    ) thin -> Self.Data
    """Callback that moves values into an allocation with a new capacity."""
    var _swap_remove: def(
        mut data: Self.Data, length: Int, remove_idx: Int
    ) thin
    """Callback that removes and destroys one value from a column."""

    @staticmethod
    def _empty_destroy(
        var data: ThinAllocation[Byte], length: Int, capacity: Int
    ):
        """Frees an empty column allocation without destroying values."""
        dealloc(data^.unsafe_with_layout(Layout[Byte](count=capacity)))

    @staticmethod
    def _empty_copy(data: Self.Data, length: Int, capacity: Int) -> Self.Data:
        """Returns no allocation for an untyped empty column."""
        return None

    @staticmethod
    def _empty_resize(
        mut data: Self.Data,
        length: Int,
        old_capacity: Int,
        new_capacity: Int,
    ) -> Self.Data:
        """Leaves an untyped empty column without allocating storage."""
        return None

    @staticmethod
    def _empty_swap_remove(mut data: Self.Data, length: Int, remove_idx: Int):
        """Does nothing because an untyped empty column has no values."""
        pass

    def __init__(out self):
        """
        Initializes an empty _ComponentColumn.
        """
        self._data = None
        self._destroy = Self._empty_destroy
        self._copy = Self._empty_copy
        self._resize = Self._empty_resize
        self._swap_remove = Self._empty_swap_remove

    @staticmethod
    def _destroy_t[
        T: ComponentType
    ](var byte_thin: ThinAllocation[Byte], length: Int, capacity: Int):
        """Destroys initialized values of type `T` and frees their allocation.

        Parameters:
            T: The component type stored by this column.

        Args:
            byte_thin: The type-erased allocation containing the values.
            length: The number of initialized values.
            capacity: The allocation capacity.
        """
        var allocation = rebind_var[ThinAllocation[T]](
            byte_thin^
        ).unsafe_with_layout(Layout[T](count=capacity))
        unsafe_destroy_n(pointer=allocation.unsafe_ptr(), count=length)
        dealloc(allocation^)

    @staticmethod
    def _copy_t[
        T: ComponentType
    ](data: Self.Data, length: Int, capacity: Int) -> Self.Data:
        """Copies initialized values of type `T` into a new allocation.

        Parameters:
            T: The component type stored by this column.

        Args:
            data: The source allocation, if present.
            length: The number of values to copy.
            capacity: The capacity of the new allocation.

        Returns:
            A type-erased allocation containing the copied values, or `None`.
        """
        if data:
            var copy_allocation = alloc(Layout[T](count=capacity))
            unsafe_uninit_copy_n[overlapping=False](
                dest=copy_allocation.unsafe_ptr(),
                src=data.value().unsafe_ptr().unsafe_bitcast[T](),
                count=length,
            )
            return {
                rebind_var[ThinAllocation[Byte]](copy_allocation^.into_thin())
            }
        return None

    @staticmethod
    def _resize_t[
        T: ComponentType
    ](
        mut data: Self.Data,
        length: Int,
        old_capacity: Int,
        new_capacity: Int,
    ) -> Self.Data:
        """Moves values of type `T` into storage with a new capacity.

        Parameters:
            T: The component type stored by this column.

        Args:
            data: The existing allocation, if present.
            length: The number of initialized values.
            old_capacity: The capacity of the existing allocation.
            new_capacity: The capacity of the new allocation.

        Returns:
            A type-erased allocation with the moved values.
        """
        var new_allocation = alloc[T](Layout[T](count=new_capacity))
        if data:
            var old_data = data.take()
            unsafe_uninit_move_n[overlapping=False](
                dest=new_allocation.unsafe_ptr(),
                src=old_data.unsafe_ptr().unsafe_bitcast[T](),
                count=length,
            )
            dealloc(
                old_data
                ^.unsafe_with_layout(
                    Layout[T](count=old_capacity).as_byte_layout()
                )
            )
        return {rebind_var[ThinAllocation[Byte]](new_allocation^.into_thin())}

    @staticmethod
    def _swap_remove_t[
        T: ComponentType
    ](mut data: Self.Data, length: Int, remove_idx: Int):
        """Destroys one value of type `T` and fills its slot from the end.

        Parameters:
            T: The component type stored by this column.

        Args:
            data: The column allocation.
            length: The current number of values.
            remove_idx: The index of the value to remove.
        """
        var ptr = data.value().unsafe_ptr().unsafe_bitcast[T]()
        unsafe_destroy_n(ptr.unsafe_offset(remove_idx), count=1)
        if remove_idx != length - 1:
            unsafe_uninit_move_n[overlapping=False](
                dest=ptr.unsafe_offset(remove_idx).as_unsafe_any_origin(),
                src=ptr.unsafe_offset(length - 1),
                count=1,
            )

    @staticmethod
    def create[
        T: ComponentType
    ](out column: Self, *, preallocate: Bool, capacity: Int):
        """Creates a column whose callbacks operate on component type `T`.

        Parameters:
            T: The component type stored by this column.

        Args:
            preallocate: Whether to allocate storage immediately.
            capacity: The initial allocation capacity.
        """
        column = Self()
        column._destroy = Self._destroy_t[T]
        column._copy = Self._copy_t[T]
        column._resize = Self._resize_t[T]
        column._swap_remove = Self._swap_remove_t[T]
        var empty: Self.Data = None
        if preallocate:
            column._data^.deinit_assert_empty()
            column._data = Self._resize_t[T](empty, 0, 0, capacity)
        empty^.deinit_assert_empty()

    def __init__(out self, *, copy: Self):
        """Initializes an empty column with the source column's callbacks."""
        self._data = None
        self._destroy = copy._destroy
        self._copy = copy._copy
        self._resize = copy._resize
        self._swap_remove = copy._swap_remove

    def __deinit__(deinit self):
        """Asserts that the column allocation was explicitly destroyed."""
        self._data^.deinit_assert_empty()

    def __bool__(self) -> Bool:
        """Returns whether the column contains initialized values."""
        return self._data.__bool__()

    def copy_data_from(mut self, source: Self, length: Int, capacity: Int):
        """Copies initialized values from another column into this column.

        Args:
            source: The source column.
            length: The number of values to copy.
            capacity: The capacity of the copied allocation.
        """
        self._data^.deinit_assert_empty()
        self._data = self._copy(source._data, length, capacity)

    def resize(mut self, length: Int, old_capacity: Int, new_capacity: Int):
        """Resizes the column allocation while preserving initialized values.

        Args:
            length: The number of initialized values.
            old_capacity: The current allocation capacity.
            new_capacity: The requested allocation capacity.
        """
        var old_data = self._data^
        self._data = self._resize(old_data, length, old_capacity, new_capacity)
        old_data^.deinit_assert_empty()

    def swap_remove(mut self, length: Int, remove_idx: Int):
        """Removes a value by replacing it with the final value in the column.

        Args:
            length: The current number of values.
            remove_idx: The index of the value to remove.
        """
        self._swap_remove(self._data, length, remove_idx)

    def destroy(mut self, length: Int, capacity: Int):
        """Destroys initialized values and releases the column allocation.

        Args:
            length: The number of initialized values.
            capacity: The allocation capacity.
        """
        if self._data:
            self._destroy(self._data.take(), length, capacity)

    def get_ptr[
        T: ComponentType
    ](ref self) -> Pointer[T, UntrackedOrigin[mut=origin_of(self).mut]]:
        """Returns a typed pointer to the first value in the column.

        Parameters:
            T: The component type stored by this column.

        Returns:
            A pointer to the column's component values.
        """
        return (
            self._data.value()
            .unsafe_ptr()
            .unsafe_bitcast[T]()
            .unsafe_origin_cast[UntrackedOrigin[mut=origin_of(self).mut]]()
        )


struct _HostComponentStorage[*ComponentTypes: ComponentType](
    Deinitable, Movable
):
    """Owns one typed host column for every configured component type."""

    comptime component_manager = ComponentManager[*Self.ComponentTypes]
    comptime Columns = Array[_ComponentColumn, len(Self.ComponentTypes)]
    var _columns: Self.Columns
    var _length: Int
    var _capacity: Int

    def __init__(out self, *, capacity: Int = DEFAULT_CAPACITY) raises:
        """Allocates all configured host component columns."""
        self._columns = Self.Columns(fill=_ComponentColumn())
        self._length = 0
        self._capacity = capacity

    @always_inline
    def __deinit__(deinit self):
        """Destroys and frees all active component buffers."""

        var capacity = self._capacity
        var length = self._length

        def destroy_column(var column: _ComponentColumn) {imm}:
            column.destroy(length, capacity)

        self._columns^.deinit_with(destroy_column)

    def init_component[T: ComponentType](mut self):
        """Initializes the host column for component ``T``."""
        comptime id = Self.component_manager.get_id[T]()

        if not self._columns[id]:
            self._columns[id] = _ComponentColumn.create[T](
                preallocate=True, capacity=self._capacity
            )

    def get_component_ptr[
        T: ComponentType
    ](ref self) -> Pointer[T, UntrackedOrigin[mut=origin_of(self).mut]]:
        """Returns the typed host column for component ``T``."""
        comptime assert Self.component_manager.contains_components[
            T
        ](), "Component type not in component manager"

        comptime id = Self.component_manager.get_id[T]()

        return self._columns[id].get_ptr[T]()

    def get_component_bytes[
        T: ComponentType
    ](ref self) -> Pointer[UInt8, UntrackedOrigin[mut=origin_of(self).mut]]:
        """Returns the byte column for component ``T``."""
        comptime id = Self.component_manager.get_id[T]()

        return self._columns[id].get_ptr[T]().unsafe_bitcast[UInt8]()


@fieldwise_init
struct DeviceComponentType:
    var dtype: DType
    var dtype_size: Int
    var size: Int
    var padding: Int


def to_device_type[T: ComponentType]() -> DeviceComponentType:
    comptime t_size = size_of[T]()
    comptime if t_size <= 1:
        return {
            dtype = DType.uint8,
            dtype_size = 1,
            size = t_size,
            padding = 1 - t_size,
        }
    comptime if t_size <= 2:
        return {
            dtype = DType.uint16,
            dtype_size = 2,
            size = t_size,
            padding = 2 - t_size,
        }
    comptime if t_size <= 4:
        return {
            dtype = DType.uint32,
            dtype_size = 4,
            size = t_size,
            padding = 4 - t_size,
        }
    comptime if t_size <= 8:
        return {
            dtype = DType.uint64,
            dtype_size = 8,
            size = t_size,
            padding = 8 - t_size,
        }
    comptime if t_size <= 16:
        return {
            dtype = DType.uint128,
            dtype_size = 16,
            size = t_size,
            padding = 16 - t_size,
        }
    comptime if t_size <= 32:
        return {
            dtype = DType.uint256,
            dtype_size = 32,
            size = t_size,
            padding = 32 - t_size,
        }
    else:
        comptime assert (
            False
        ), "Only types with sizes <= 32 are supported on the GPU"


struct _DeviceComponentStorage[*ComponentTypes: ComponentType](Movable):
    """Owns one byte-addressed device column per configured component type."""

    comptime component_manager = ComponentManager[*Self.ComponentTypes]

    comptime Columns = Array[
        Optional[DeviceBuffer[DType.uint8]], len(Self.ComponentTypes)
    ]
    var _columns: Self.Columns
    var _length: Int
    var _capacity: Int
    var _device_context: DeviceContext

    def __init__(
        out self,
        var device_context: DeviceContext,
        *,
        capacity: Int = DEFAULT_CAPACITY,
    ) raises:
        """Allocates all configured device component columns."""
        self._columns = Self.Columns(fill=None)
        self._device_context = device_context^
        self._length = 0
        self._capacity = capacity

    def fill[T: ComponentType](mut self, var value: T) raises:
        comptime id = Self.component_manager.get_id[T]()
        if self._columns[id] is None:
            self._columns[id] = {
                self._device_context.create_buffer_sync[DType.uint8](
                    size_of[T]() * self._capacity
                )
            }

        comptime device_type = to_device_type[T]()

        var aligned_sub_buffer = (
            self._columns[id]
            .unsafe_value()
            .create_sub_buffer[device_type.dtype](offset=0, size=self._capacity)
        )
        self._device_context.synchronize()
        var gpu_value = Array[UInt8, device_type.dtype_size](fill=0)
        var bytes_ptr = Pointer(to=value).unsafe_bitcast[UInt8]()
        comptime for i in range(device_type.size):
            gpu_value[i] = bytes_ptr[unsafe_offset=i]
        aligned_sub_buffer.enqueue_fill(
            gpu_value.unsafe_ptr().unsafe_bitcast[Scalar[device_type.dtype]]()[]
        )
        self._device_context.synchronize()
        self._length = self._capacity

    def copy_to_host[T: ComponentType](self, out data: List[T]) raises:
        comptime id = Self.component_manager.get_id[T]()
        comptime device_type = to_device_type[T]()

        if self._columns[id] is None:
            return List[T](capacity=0)

        # TODO: handle the `device_type.padding` correctly
        var bytes = List[UInt8](
            length=self._capacity * device_type.size, fill=0
        )
        self._columns[id].unsafe_value().enqueue_copy_to(bytes.unsafe_ptr())
        self._device_context.synchronize()
        data = rebind_var[List[T]](bytes^)


@fieldwise_init
struct _World[*WorldTs: ComponentType]:
    comptime component_manager = ComponentManager[*Self.WorldTs]
    comptime host_storage_type = _HostComponentStorage[*Self.WorldTs]
    comptime device_storage_type = _DeviceComponentStorage[*Self.WorldTs]

    var device: DeviceContext
    var host_storage: Self.host_storage_type
    var device_storage: Self.device_storage_type

    def __init__(out self) raises:
        """Creates and initializes the demo component columns on the GPU."""
        self.device = DeviceContext()

        # This demo owns one row for every logical entity. Keep the backing
        # allocations and the logical lengths in sync with that row count.
        self.device_storage = Self.device_storage_type(
            self.device, capacity=entity_count
        )
        self.device.synchronize()

        self.host_storage = Self.host_storage_type(capacity=entity_count)

        self.host_storage.init_component[Position]()
        self.host_storage.init_component[Velocity]()

        var host_position = self.host_storage.get_component_ptr[Position]()
        var host_velocity = self.host_storage.get_component_ptr[Velocity]()
        for i in range(entity_count):
            var x = Float32(i)
            var y = Float32(-i)
            host_position[unsafe_offset=i] = Position(x=x, y=y)
            host_velocity[unsafe_offset=i] = Velocity(dx=2.0, dy=-2.0)
        self.host_storage._length = entity_count


@fieldwise_init
struct EntityAccessor(Copyable):
    """Device-side accessor for one logical entity row."""

    var id: Int32
    var _position: Pointer[UInt8, MutUntrackedOrigin]
    var _velocity: Pointer[UInt8, MutUntrackedOrigin]

    def get[T: ComponentType](self) -> ref[MutUntrackedOrigin] T:
        """Loads a component value for this entity from device storage."""
        comptime if T == Position:
            var position = rebind[Pointer[Position, MutUntrackedOrigin]](
                self._position.unsafe_offset(Int(self.id) * size_of[Position]())
            )
            return rebind[T](position[])
        elif T == Velocity:
            var velocity = rebind[Pointer[Velocity, MutUntrackedOrigin]](
                self._velocity.unsafe_offset(Int(self.id) * size_of[Velocity]())
            )
            return rebind[T](velocity[])
        else:
            comptime assert False, "Component is not available in this kernel."

    def set[T: ComponentType](self, var component: T):
        """Stores a component value for this entity in device storage."""
        comptime if T == Position:
            var position = rebind_var[Position](component^)
            var target = rebind[Pointer[Position, MutUntrackedOrigin]](
                self._position.unsafe_offset(Int(self.id) * size_of[Position]())
            )
            target[] = position^
        elif T == Velocity:
            var velocity = rebind_var[Velocity](component^)
            var target = rebind[Pointer[Velocity, MutUntrackedOrigin]](
                self._velocity.unsafe_offset(Int(self.id) * size_of[Velocity]())
            )
            target[] = velocity^
        else:
            comptime assert False, "Component is not available in this kernel."


struct EntityAccessorIterator(Iterator, Movable):
    comptime Element = EntityAccessor

    var _entity: EntityAccessor
    var _length: Int32
    var _done: Bool
    var _one_entity: Bool

    def __init__(out self, context: KernelContext):
        self._entity = EntityAccessor(
            id=0,
            _position=context.position,
            _velocity=context.velocity,
        )
        self._length = context.length
        self._done = False
        self._one_entity = True

    def __iter__(deinit self) -> Self:
        return self^

    def __next__(mut self) raises StopIteration -> Self.Element:
        if self._done or self._entity.id >= self._length:
            raise StopIteration()
        var entity = self._entity.copy()
        if self._one_entity:
            self._done = True
        else:
            self._entity.id += 1
        return entity^


@fieldwise_init
struct KernelContext(Copyable, RegisterPassable):
    var length: Int32
    var position: Pointer[UInt8, MutUntrackedOrigin]
    var velocity: Pointer[UInt8, MutUntrackedOrigin]

    def __iter__(self) -> EntityAccessorIterator:
        return EntityAccessorIterator(self)


@fieldwise_init
struct HostKernelContext(Copyable, DevicePassable, RegisterPassable):
    """Device-passable view of the component columns used by a kernel."""

    comptime device_type = KernelContext

    @staticmethod
    def get_type_name() -> String:
        """Returns the host type name used in device diagnostics."""
        return "KernelContext"

    var length: Int32
    var position: DevicePointer[
        mut=True, dtype=DType.uint8, origin=MutUntrackedOrigin
    ]
    var velocity: DevicePointer[
        mut=True, dtype=DType.uint8, origin=MutUntrackedOrigin
    ]

    def _to_device_type[
        Encoder: DeviceTypeEncoder
    ](
        self,
        mut encoder: Encoder,
        target: Pointer[mut=True, T=NoneType, origin=_],
    ):
        """Encodes device buffers as their device-side pointer fields."""
        encoder.encode_fields[
            StructType=Self, DeviceStructType=Self.device_type
        ](self, target)


@fieldwise_init
struct Context[
    world_origin: Origin[mut=True],
    *WorldTs: ComponentType,
]:
    comptime World = _World[*Self.WorldTs]
    comptime filter = Filter[]

    var _world: Pointer[Self.World, Self.world_origin]

    def __init__(out self, ref[Self.world_origin] world: Self.World):
        """Creates a context borrowing the scheduler's world."""
        self._world = Pointer(to=world)

    def run[
        KernelFunc: def(KernelContext) thin -> None,
        filter: Filter,
        *,
        on_gpu: Bool = False,
    ](mut self) raises:
        """Runs a system function over generic host component columns."""
        comptime if on_gpu:
            var kernel_context = HostKernelContext(
                length=Int32(self._world[].device_storage._length),
                position=rebind[
                    DevicePointer[
                        mut=True, dtype=DType.uint8, origin=MutUntrackedOrigin
                    ]
                ](
                    DevicePointer(
                        self._world[]
                        .device_storage._columns[
                            Self.World.component_manager.get_id[Position]()
                        ]
                        .unsafe_value()
                    )
                ),
                velocity=rebind[
                    DevicePointer[
                        mut=True, dtype=DType.uint8, origin=MutUntrackedOrigin
                    ]
                ](
                    DevicePointer(
                        self._world[]
                        .device_storage._columns[
                            Self.World.component_manager.get_id[Velocity]()
                        ]
                        .unsafe_value()
                    )
                ),
            )
            self._world[].device.enqueue_function[KernelFunc](
                kernel_context,
                grid_dim=block_count,
                block_dim=block_size,
            )
            self._world[].device.synchronize()
        else:
            var kernel_context = KernelContext(
                length=Int32(self._world[].host_storage._length),
                position=self._world[].host_storage.get_component_bytes[
                    Position
                ](),
                velocity=self._world[].host_storage.get_component_bytes[
                    Velocity
                ](),
            )
            KernelFunc(kernel_context)


trait System(Copyable, Deinitable):
    def update[
        *WorldTs: ComponentType
    ](mut self, mut context: Context[_, *WorldTs]) raises:
        ...


def move_positions(context: KernelContext):
    for entity in context:
        ref position = entity.get[Position]()
        ref velocity = entity.get[Velocity]()
        position.x += velocity.dx
        position.y += velocity.dy


@fieldwise_init
struct Move(System):
    def update[
        *WorldTs: ComponentType
    ](mut self, mut context: Context[_, *WorldTs]) raises:
        """Runs the movement kernel for entities with position and velocity."""
        context.run[
            move_positions,
            context.filter.include[Position, Velocity](),
            on_gpu=True,
        ]()

        context.run[
            move_positions,
            context.filter.include[Position, Velocity](),
            on_gpu=False,
        ]()


def _update_system[
    S: System, *ComponentTypes: ComponentType
](
    mut system: UnsafeBox, ref[MutUntrackedOrigin] world: _World[*ComponentTypes]
) raises:
    """Updates one type-erased system with a mutable borrowed world reference."""
    with Zone(function_name=String(t"{reflect[S].name()}.update()")):
        ref concrete_system = system.unsafe_get[S]()
        var context = Context[MutUntrackedOrigin, *ComponentTypes](world)
        S.update[*ComponentTypes](concrete_system, context)


@fieldwise_init
struct Scheduler[*WorldComponentTypes: ComponentType]:
    comptime World = _World[*Self.WorldComponentTypes]
    comptime FunctionType = def(
        mut system: UnsafeBox, ref[MutUntrackedOrigin] world: Self.World
    ) thin raises

    comptime _system_index = 0
    comptime _update_index = 1

    var world: Self.World
    var _systems: List[Tuple[UnsafeBox, Self.FunctionType]]

    def __init__(out self) raises:
        """Creates a scheduler with one initialized world."""
        self.world = Self.World()
        self._systems = List[Tuple[UnsafeBox, Self.FunctionType]]()

    def add_system[S: System](mut self, var system: S):
        """Registers a system in update order."""
        self._systems.append(
            (UnsafeBox(system^), _update_system[S, *Self.WorldComponentTypes])
        )

    def update(mut self, steps: Int = 1) raises:
        """Runs all registered systems for the requested number of steps."""
        for _ in range(steps):
            for ref system_info in self._systems:
                var world_ptr = Pointer(to=self.world).unsafe_origin_cast[
                    MutUntrackedOrigin
                ]()
                system_info[Self._update_index](
                    system_info[Self._system_index], world_ptr[]
                )
        frame_mark()


def main() raises:
    comptime if not has_accelerator():
        print("No compatible GPU found")
    else:
        var scheduler = Scheduler[Position, Velocity, Name]()
        scheduler.world.device_storage.fill[Position](Position(0.0, 0.0))
        scheduler.world.device_storage.fill[Velocity](Velocity(1.0, -1.0))
        scheduler.add_system(Move())
        scheduler.update()

        # Capture the host value before copying the device buffer. The device
        # copy returns a separate list and must not be used as a host-storage
        # synchronization operation.
        var host_position_ptr = scheduler.world.host_storage.get_component_ptr[
            Position
        ]()
        var host_position = host_position_ptr[unsafe_offset=0].copy()
        print(t"Host position[0] = ({ host_position.x }, { host_position.y })")

        var gpu_positions = scheduler.world.device_storage.copy_to_host[
            Position
        ]()
        print(
            t"GPU position[0] = ({ gpu_positions[0].x },"
            t" { gpu_positions[0].y })"
        )
