"""Minimal GPU-backed sketch of the systems API.

It demonstrates the first execution boundary: the CPU path runs against the
archetype-backed ECS storage, while the GPU path owns device-resident SoA
component columns, launches a Mojo GPU kernel, and copies results back only for
verification.
"""

from max.gpu.host import DeviceBuffer, DeviceContext, DevicePointer, HostBuffer
from std.builtin.device_passable import DevicePassable, DeviceTypeEncoder
from std.gpu import global_idx
from std.math import ceildiv
from std.sys import has_accelerator, size_of
from std.sys.info import is_gpu

from larecs.component import ComponentType, ComponentManager
from larecs.storage import Storage
from larecs.unsafe_box import UnsafeBox
from larecs.bitmask import BitMask

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
comptime entity_count = 255
comptime block_size = 128

# The kernel body is independent of the execution backend. The backend adapter
# below is responsible for constructing the matching context and launching it.
comptime run_on_gpu = True


@fieldwise_init
struct Components[*ComponentTypes: ComponentType](Sized):
    def __len__(self) -> Int:
        """Returns the number of component types included by the filter."""
        return len(self.ComponentTypes)


@fieldwise_init
struct Filter[
    _include: Components = Components[](), _exclude: Components = Components[]()
](Sized):
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

    def __len__(self) -> Int:
        """Returns the number of components included by the filter."""
        comptime include_length = len(self._include)
        return include_length

    def includes[T: ComponentType](self) -> Int:
        """Returns whether a filter includes component ``T``.

        Parameters:
            T: The component type to search for.

        Returns:
            The component index when ``T`` is included; otherwise ``-1``.
        """
        comptime for i in range(len(Self._include)):
            comptime if Self._include.ComponentTypes[i] == T:
                return i
        return -1

    def excludes[
        T: ComponentType,
    ](self) -> Int:
        """Returns whether a filter excludes component ``T``.

        Parameters:
            T: The component type to search for.

        Returns:
            The component index when ``T`` is excluded; otherwise ``-1``.
        """
        comptime for i in range(len(Self._exclude)):
            comptime if Self._exclude.ComponentTypes[i] == T:
                return i
        return -1

    def get_include_mask[*ComponentTypes: ComponentType](self) -> BitMask:
        comptime component_manager = ComponentManager[*ComponentTypes]
        return BitMask(component_manager.get_id_arr[*Self._include.ComponentTypes]())
    def get_exclude_mask[*ComponentTypes: ComponentType](self) -> BitMask:
        comptime component_manager = ComponentManager[*ComponentTypes]
        return BitMask(component_manager.get_id_arr[*Self._exclude.ComponentTypes]())


@fieldwise_init
struct DeviceComponentType:
    var dtype: DType
    var dtype_size: Int
    var size: Int
    var padding: Int

struct _DeviceComponentStorage[*ComponentTypes: ComponentType](Movable):
    """Owns one byte-addressed device column per configured component type."""

    comptime component_manager = ComponentManager[*Self.ComponentTypes]

    comptime Columns = Array[
        Optional[DeviceBuffer[DType.uint8]], len(Self.ComponentTypes)
    ]
    var _columns: Self.Columns
    var _length: Int
    var _device_context: DeviceContext

    def __init__(
        out self,
        var device_context: DeviceContext,
        length: Int,
    ) raises:
        """Allocates all configured device component columns."""
        self._columns = Self.Columns(fill=None)
        self._device_context = device_context^
        self._length = length

    def has_component[T: ComponentType](self) -> Bool:
        """Returns whether the device column for ``T`` is initialized.

        Parameters:
            T: The component type to check.

        Returns:
            ``True`` when the component has an initialized device column.
        """
        comptime assert Self.component_manager.contains_components[
            T
        ](), "Component type not in component manager"
        comptime id = Self.component_manager.get_id[T]()
        return Bool(self._columns[id])

    def copy_to_host[T: ComponentType](self, out data: List[T]) raises:
        comptime id = Self.component_manager.get_id[T]()

        if self._columns[id] is None:
            return List[T](capacity=0)

        var bytes = List[UInt8](
            length=self._length * size_of[T](), fill=0
        )
        self._columns[id].unsafe_value().enqueue_copy_to(bytes.unsafe_ptr())
        self._device_context.synchronize()
        data = rebind_var[List[T]](bytes^)

    def copy_from_host[mut: Bool, origin: Origin[mut=mut], // , T: ComponentType](mut self, data: Span[T, origin], *, offset: Int = 0) raises:
        comptime id = Self.component_manager.get_id[T]()

        if len(data) == 0:
            return

        if self._length <= (len(data) + offset):
            self._length = len(data) + offset


        if self._columns[id] is None:
            self._columns[id] = { self._device_context.create_buffer_sync[DType.uint8](self._length * size_of[T]()) }

        if len(self._columns[id].unsafe_value()) != self._length:
            var new_buffer = self._device_context.create_buffer_sync[DType.uint8](self._length * size_of[T]())
            self._columns[id].unsafe_value().enqueue_copy_to(new_buffer)
            self._columns[id] = { new_buffer^ }


        var sub_buffer = self._columns[id].unsafe_value().create_sub_buffer[DType.uint8](offset * size_of[T](), len(data) * size_of[T]())
        sub_buffer.enqueue_copy_from(data.unsafe_ptr().unsafe_bitcast[UInt8]())

    def get_device_ptr[T: ComponentType](mut self) raises -> DevicePointer[mut=True, DType.uint8, MutUntrackedOrigin]:
        comptime id = Self.component_manager.get_id[T]()
        if self._columns[id] is None:
            raise "Column not initialized"
        return rebind[DevicePointer[mut=True, DType.uint8, MutUntrackedOrigin]](
            self._columns[id].unsafe_value().device_ptr()
        )

    def synchronize(self) raises:
        self._device_context.synchronize()


@fieldwise_init
struct _World[*WorldTs: ComponentType]:
    comptime component_manager = ComponentManager[*Self.WorldTs]
    comptime host_storage_type = Storage[*Self.WorldTs]
    comptime device_storage_type = _DeviceComponentStorage[*Self.WorldTs]

    var device: DeviceContext
    var host_storage: Self.host_storage_type
    var device_storage: Self.device_storage_type

    def __init__(out self) raises:
        """Creates and initializes the demo component columns on the GPU."""
        self.device = DeviceContext()

        # This demo owns one row for every logical entity. Keep the backing
        # allocations and the logical lengths in sync with that row count.
        self.device_storage = Self.device_storage_type(self.device, length=0)
        self.device.synchronize()

        self.host_storage = Self.host_storage_type()

        # Store host entities in the archetype-backed ECS storage. This keeps
        # the CPU system on the same entity/component model as the public API
        # instead of treating the world as a pair of untyped dense columns.
        for i in range(entity_count):
            var x = Float32(i)
            var y = Float32(-i)
            _ = self.host_storage.add_entity(
                Position(x=x, y=y),
                Velocity(dx=2.0, dy=-2.0),
            )


@fieldwise_init
struct EntityAccessor[KernelFilter: Filter](Copyable):
    """Device-side accessor for one logical entity row."""

    var id: Int32
    var _component_table_base: Array[Pointer[UInt8, MutUntrackedOrigin], len(Self.KernelFilter)]

    def get[T: ComponentType](self) -> ref[MutUntrackedOrigin] T:
        """Loads an included component value for this entity."""
        comptime comp_idx = Self.KernelFilter.includes[T]()
        comptime assert comp_idx != -1, "Component type is not included by the kernel filter"
        return self._component_table_base[comp_idx].unsafe_bitcast[T]()[unsafe_offset=self.id]

    def set[T: ComponentType](self, var component: T):
        """Stores a component value for this entity in device storage."""
        comptime comp_idx = Self.KernelFilter.includes[T]()
        comptime assert comp_idx != -1, "Component type is not included by the kernel filter"
        self._component_table_base[comp_idx].unsafe_bitcast[T]()[unsafe_offset=self.id] = component^

struct EntityAccessorIterator[KernelFilter: Filter](Iterator, Movable):
    comptime Element = EntityAccessor[Self.KernelFilter]

    var _entity: EntityAccessor[Self.KernelFilter]
    var _length: Int32
    var _stride: Int32
    var _done: Bool

    def __init__(out self, context: KernelContext[Self.KernelFilter]):
        var start: Int32 = 0
        var stride: Int32 = 1
        comptime if is_gpu():
            start = Int32(global_idx.x)
            stride = context.thread_count

        self._entity = EntityAccessor[Self.KernelFilter](
            id=start,
            _component_table_base=context._columns.copy(),
        )
        self._length = context.length
        self._stride = stride
        self._done = False

    def __iter__(deinit self) -> Self:
        return self^

    def __next__(mut self) raises StopIteration -> Self.Element:
        if self._done or self._entity.id >= self._length:
            raise StopIteration()
        var entity = self._entity.copy()
        self._entity.id += self._stride
        return entity^


@fieldwise_init
struct KernelContext[kernel_filter: Filter](Copyable):
    var length: Int32
    var thread_count: Int32

    comptime Columns = Array[Pointer[UInt8, MutUntrackedOrigin], len(Self.kernel_filter)]
    var _columns: Self.Columns

    def __init__(out self, var columns: Self.Columns, *, length: Int32, thread_count: Int32):
        self.length = length
        self.thread_count = thread_count
        self._columns = columns^

    def __iter__(self) -> EntityAccessorIterator[Self.kernel_filter]:
        return EntityAccessorIterator[Self.kernel_filter](self)


@fieldwise_init
struct HostKernelContext[kernel_filter: Filter](
    Copyable, DevicePassable
):
    """Device-passable view of the component columns used by a kernel."""

    comptime device_type = KernelContext[Self.kernel_filter]

    @staticmethod
    def get_type_name() -> String:
        """Returns the host type name used in device diagnostics."""
        return "KernelContext"

    var length: Int32
    var thread_count: Int32
    comptime Columns = Array[DevicePointer[mut=True, dtype=DType.uint8, origin=MutUntrackedOrigin], len(Self.kernel_filter)]
    var _columns: Self.Columns

    def __init__(
        out self,
        var columns: Self.Columns,
        *,
        length: Int32,
        thread_count: Int32,
    ):
        self._columns = columns^
        self.length = length
        self.thread_count = thread_count

    def _to_device_type[
        Encoder: DeviceTypeEncoder
    ](
        self,
        mut encoder: Encoder,
        target: Pointer[mut=True, T=NoneType, origin=_],
    ):
        """Encodes device buffers as their device-side pointer fields."""

        var dst = target.unsafe_bitcast[Self.device_type]()

        dst[].length = self.length
        dst[].thread_count = self.thread_count

        dst[]._columns = Array[Pointer[UInt8, MutUntrackedOrigin], len(Self.kernel_filter)](uninitialized=True)

        comptime for i in range(len(Self.kernel_filter)):
            dst[]._columns[i] = self._columns[i].buffer().unsafe_ptr()



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
        filter: Filter,
        //,
        KernelFunc: def(KernelContext[filter]) thin -> None,
        *,
        on_gpu: Bool = False,
    ](mut self) raises:
        """Runs a system function over rows matching ``filter``.

        Parameters:
            filter: Compile-time component inclusion and exclusion constraints.
            KernelFunc: The kernel specialized for ``filter``.
            on_gpu: Whether to execute the kernel against device storage.
        """
        var length = 0
        comptime include_mask = filter.get_include_mask[*Self.WorldTs]()
        comptime exclude_mask = filter.get_exclude_mask[*Self.WorldTs]()
        var matching_archetypes = self._world[].host_storage._get_archetype_iterator(
            include_mask,
            exclude_mask,
        )
        for ref archetype in matching_archetypes.copy():
            length += len(archetype)

        comptime if on_gpu:
            self._world[].device_storage = Self.World.device_storage_type(self._world[].device, length)

            var kernel_columns = HostKernelContext[filter].Columns(uninitialized=True)

            comptime for i in range(len(filter)):
                comptime T = filter._include.ComponentTypes[i]

                for ref archetype in matching_archetypes.copy():
                    self._world[].device_storage.copy_from_host[T](archetype._storage.get_component_span[T]())

                kernel_columns[i] = self._world[].device_storage.get_device_ptr[T]()

            var grid_dim = ceildiv(length, block_size)
            if length > 0:
                var kernel_context = HostKernelContext[filter](
                    kernel_columns^,
                    length=Int32(length),
                    thread_count=Int32(grid_dim * block_size),
                )
                self._world[].device.enqueue_function[KernelFunc](
                    kernel_context,
                    grid_dim=grid_dim,
                    block_dim=block_size,
                )
                self._world[].device.synchronize()
        else:
            # A filter can match multiple archetypes. Run the kernel once per
            # matching archetype so each component pointer refers to a
            # homogeneous SoA range and the accessor's row id remains local to
            # that archetype.
            for ref archetype in matching_archetypes^:
                var kernel_columns = KernelContext[filter].Columns(uninitialized=True)

                comptime for i in range(len(filter)):
                    comptime T = filter._include.ComponentTypes[i]
                    kernel_columns[i] = archetype._storage.get_component_ptr[T]().unsafe_bitcast[UInt8]()

                var kernel_context = KernelContext[filter](
                    kernel_columns^,
                    length=Int32(length),
                    thread_count=1,
                )
                KernelFunc(kernel_context)


trait System(Copyable, Deinitable):
    def update[
        *WorldTs: ComponentType
    ](mut self, mut context: Context[_, *WorldTs]) raises:
        ...


def move_positions[KernelFilter: Filter](
    context: KernelContext[KernelFilter]
):
    """Moves every position in the kernel's assigned row range.

    Args:
        context: The CPU or GPU execution context for the filtered rows.
    """
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
            move_positions[context.filter.include[Position, Velocity]()],
            on_gpu=True,
        ]()

        context.run[
            move_positions[context.filter.include[Position, Velocity]()],
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
        # scheduler.world.device_storage.fill[Position](Position(0.0, 0.0))
        # scheduler.world.device_storage.fill[Velocity](Velocity(1.0, -1.0))

        # Add an entity with a different component composition. The CPU
        # filter must skip this archetype while still updating the matching
        # Position + Velocity archetype.
        var static_entity = scheduler.world.host_storage.add_entity(
            Position(x=1000.0, y=-1000.0)
        )

        scheduler.add_system(Move())
        scheduler.update()

        # Capture the host value before copying the device buffer. The device
        # copy returns a separate list and must not be used as a host-storage
        # synchronization operation.
        var host_index = 0
        for entity in scheduler.world.host_storage.query[Position, Velocity]():
            if host_index == 0:
                print(
                    t"Host position[0] = ({ entity.get[Position]().x },"
                    t" { entity.get[Position]().y })"
                )
                assert entity.get[Position]().x == 2.0
                assert entity.get[Position]().y == -2.0
            elif host_index == 1:
                assert entity.get[Position]().x == 3.0
                assert entity.get[Position]().y == -3.0
            elif host_index == entity_count - 1:
                assert entity.get[Position]().x == Float32(entity_count + 1)
                assert entity.get[Position]().y == -Float32(entity_count + 1)
            host_index += 1
        assert host_index == entity_count
        assert scheduler.world.host_storage.get[Position](static_entity).x == 1000.0
        assert scheduler.world.host_storage.get[Position](static_entity).y == -1000.0

        var gpu_positions = scheduler.world.device_storage.copy_to_host[
            Position
        ]()
        print(
            t"GPU position[0] = ({ gpu_positions[0].x },"
            t" { gpu_positions[0].y })"
        )
        assert gpu_positions[0].x == 1.0
        assert gpu_positions[0].y == -1.0
        assert gpu_positions[1].x == 1.0
        assert gpu_positions[1].y == -1.0
        assert gpu_positions[entity_count - 1].x == 1.0
        assert gpu_positions[entity_count - 1].y == -1.0
