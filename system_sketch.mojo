"""Minimal GPU-backed sketch of the systems API.

This is intentionally not the ECS storage implementation yet. It demonstrates
the first execution boundary: a filtered system run owns device-resident SoA
component columns, launches a Mojo GPU kernel, and copies results back only for
verification.
"""

from max.gpu.host import DeviceBuffer, DeviceContext, DevicePointer
from std.builtin.device_passable import DevicePassable, DeviceTypeEncoder
from std.gpu import global_idx
from std.math import ceildiv
from std.memory import Layout, ThinAllocation, alloc, dealloc
from std.sys import has_accelerator

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


comptime float_dtype = DType.float32
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


@fieldwise_init
struct _World[*WorldTs: ComponentType]:
    comptime component_manager = ComponentManager[*Self.WorldTs]

    var device: DeviceContext
    var position_x: DeviceBuffer[float_dtype]
    var position_y: DeviceBuffer[float_dtype]
    var velocity_x: DeviceBuffer[float_dtype]
    var velocity_y: DeviceBuffer[float_dtype]
    var host_position_x: ThinAllocation[Float32]
    var host_position_y: ThinAllocation[Float32]
    var host_velocity_x: ThinAllocation[Float32]
    var host_velocity_y: ThinAllocation[Float32]

    def __init__(out self) raises:
        """Creates and initializes the demo component columns on the GPU."""
        self.device = DeviceContext()

        var position_x_host = self.device.enqueue_create_host_buffer[
            float_dtype
        ](entity_count)
        var position_y_host = self.device.enqueue_create_host_buffer[
            float_dtype
        ](entity_count)
        var velocity_x_host = self.device.enqueue_create_host_buffer[
            float_dtype
        ](entity_count)
        var velocity_y_host = self.device.enqueue_create_host_buffer[
            float_dtype
        ](entity_count)

        self.position_x = self.device.enqueue_create_buffer[float_dtype](
            entity_count
        )
        self.position_y = self.device.enqueue_create_buffer[float_dtype](
            entity_count
        )
        self.velocity_x = self.device.enqueue_create_buffer[float_dtype](
            entity_count
        )
        self.velocity_y = self.device.enqueue_create_buffer[float_dtype](
            entity_count
        )
        self.host_position_x = alloc[Float32](
            Layout[Float32](count=entity_count)
        ).into_thin()
        self.host_position_y = alloc[Float32](
            Layout[Float32](count=entity_count)
        ).into_thin()
        self.host_velocity_x = alloc[Float32](
            Layout[Float32](count=entity_count)
        ).into_thin()
        self.host_velocity_y = alloc[Float32](
            Layout[Float32](count=entity_count)
        ).into_thin()
        self.device.synchronize()

        for i in range(entity_count):
            var x = Float32(i)
            var y = Float32(-i)
            self.host_position_x.unsafe_ptr()[unsafe_offset=i] = x
            self.host_position_y.unsafe_ptr()[unsafe_offset=i] = y
            self.host_velocity_x.unsafe_ptr()[unsafe_offset=i] = 2.0
            self.host_velocity_y.unsafe_ptr()[unsafe_offset=i] = -2.0
            position_x_host[i] = x
            position_y_host[i] = y
            velocity_x_host[i] = 1.0
            velocity_y_host[i] = -1.0

        self.device.enqueue_copy(self.position_x, position_x_host)
        self.device.enqueue_copy(self.position_y, position_y_host)
        self.device.enqueue_copy(self.velocity_x, velocity_x_host)
        self.device.enqueue_copy(self.velocity_y, velocity_y_host)
        self.device.synchronize()

    def __deinit__(deinit self):
        """Releases the host-resident component columns."""
        dealloc(
            self.host_position_x
            ^.unsafe_with_layout(Layout[Float32](count=entity_count))
        )
        dealloc(
            self.host_position_y
            ^.unsafe_with_layout(Layout[Float32](count=entity_count))
        )
        dealloc(
            self.host_velocity_x
            ^.unsafe_with_layout(Layout[Float32](count=entity_count))
        )
        dealloc(
            self.host_velocity_y
            ^.unsafe_with_layout(Layout[Float32](count=entity_count))
        )


@fieldwise_init
struct EntityAccessor(Copyable):
    """Device-side accessor for one logical entity row."""

    var id: Int32
    var _position_x: Pointer[Float32, MutUntrackedOrigin]
    var _position_y: Pointer[Float32, MutUntrackedOrigin]
    var _velocity_x: Pointer[Float32, MutUntrackedOrigin]
    var _velocity_y: Pointer[Float32, MutUntrackedOrigin]

    def get[T: ComponentType](self) -> T:
        """Loads a component value for this entity from device storage."""
        comptime if T == Position:
            return rebind_var[T](
                Position(
                    x=self._position_x[unsafe_offset=self.id],
                    y=self._position_y[unsafe_offset=self.id],
                )
            )
        elif T == Velocity:
            return rebind_var[T](
                Velocity(
                    dx=self._velocity_x[unsafe_offset=self.id],
                    dy=self._velocity_y[unsafe_offset=self.id],
                )
            )
        else:
            comptime assert False, "Component is not available in this kernel."

    def set[T: ComponentType](self, var component: T):
        """Stores a component value for this entity in device storage."""
        comptime if T == Position:
            var position = rebind_var[Position](component^)
            self._position_x[unsafe_offset=self.id] = position.x
            self._position_y[unsafe_offset=self.id] = position.y
        elif T == Velocity:
            var velocity = rebind_var[Velocity](component^)
            self._velocity_x[unsafe_offset=self.id] = velocity.dx
            self._velocity_y[unsafe_offset=self.id] = velocity.dy
        else:
            comptime assert False, "Component is not available in this kernel."


struct EntityAccessorIterator(Iterator, Movable):
    comptime Element = EntityAccessor

    var _entity: EntityAccessor
    var _done: Bool

    def __init__(out self, context: DeviceKernelContext):
        self._entity = EntityAccessor(
            id=0,
            _position_x=context.position_x,
            _position_y=context.position_y,
            _velocity_x=context.velocity_x,
            _velocity_y=context.velocity_y,
        )
        self._done = False

    def __iter__(deinit self) -> Self:
        return self^

    def __next__(mut self) raises StopIteration -> Self.Element:
        if self._done or self._entity.id >= entity_count:
            raise StopIteration()
        self._done = True
        return self._entity.copy()


@fieldwise_init
struct DeviceKernelContext(Copyable, RegisterPassable):
    """The device representation of ``KernelContext``."""

    var position_x: Pointer[Float32, MutUntrackedOrigin]
    var position_y: Pointer[Float32, MutUntrackedOrigin]
    var velocity_x: Pointer[Float32, MutUntrackedOrigin]
    var velocity_y: Pointer[Float32, MutUntrackedOrigin]

    def __iter__(self) -> EntityAccessorIterator:
        return EntityAccessorIterator(self)


@fieldwise_init
struct KernelContext(Copyable, DevicePassable, RegisterPassable):
    """Device-passable view of the component columns used by a kernel."""

    comptime device_type = DeviceKernelContext

    @staticmethod
    def get_type_name() -> String:
        """Returns the host type name used in device diagnostics."""
        return "KernelContext"

    var position_x: DevicePointer[
        mut=True, dtype=float_dtype, origin=MutUntrackedOrigin
    ]
    var position_y: DevicePointer[
        mut=True, dtype=float_dtype, origin=MutUntrackedOrigin
    ]
    var velocity_x: DevicePointer[
        mut=True, dtype=float_dtype, origin=MutUntrackedOrigin
    ]
    var velocity_y: DevicePointer[
        mut=True, dtype=float_dtype, origin=MutUntrackedOrigin
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
        KernelFunc: def(DeviceKernelContext) thin -> None,
        filter: Filter,
        *,
        on_gpu: Bool = False,
    ](mut self) raises:
        """Runs a system function over host-resident component columns."""
        comptime if on_gpu:
            var kernel_context = KernelContext(
                position_x=rebind[
                    DevicePointer[
                        mut=True, dtype=float_dtype, origin=MutUntrackedOrigin
                    ]
                ](DevicePointer(self._world[].position_x)),
                position_y=rebind[
                    DevicePointer[
                        mut=True, dtype=float_dtype, origin=MutUntrackedOrigin
                    ]
                ](DevicePointer(self._world[].position_y)),
                velocity_x=rebind[
                    DevicePointer[
                        mut=True, dtype=float_dtype, origin=MutUntrackedOrigin
                    ]
                ](DevicePointer(self._world[].velocity_x)),
                velocity_y=rebind[
                    DevicePointer[
                        mut=True, dtype=float_dtype, origin=MutUntrackedOrigin
                    ]
                ](DevicePointer(self._world[].velocity_y)),
            )
            self._world[].device.enqueue_function[KernelFunc](
                kernel_context,
                grid_dim=block_count,
                block_dim=block_size,
            )
            self._world[].device.synchronize()
        else:
            var kernel_context = DeviceKernelContext(
                position_x=rebind[Pointer[Float32, MutUntrackedOrigin]](
                    self._world[].host_position_x.unsafe_ptr()
                ),
                position_y=rebind[Pointer[Float32, MutUntrackedOrigin]](
                    self._world[].host_position_y.unsafe_ptr()
                ),
                velocity_x=rebind[Pointer[Float32, MutUntrackedOrigin]](
                    self._world[].host_velocity_x.unsafe_ptr()
                ),
                velocity_y=rebind[Pointer[Float32, MutUntrackedOrigin]](
                    self._world[].host_velocity_y.unsafe_ptr()
                ),
            )
            KernelFunc(kernel_context)


trait System(Copyable, Deinitable):
    def update[
        *WorldTs: ComponentType
    ](mut self, mut context: Context[_, *WorldTs]) raises:
        ...


def move_positions(context: DeviceKernelContext):
    """Adapts the shared movement body to the GPU kernel ABI.

    The device-side context is passed to one GPU launch.
    """
    for entity in context:
        var position = entity.get[Position]()
        var velocity = entity.get[Velocity]()
        position.x += velocity.dx
        position.y += velocity.dy
        entity.set[Position](position^)


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
](mut system: UnsafeBox, mut world: _World[*ComponentTypes]) raises:
    """Updates one type-erased system with a borrowed GPU world context."""
    with Zone(function_name=String(t"{reflect[S].name()}.update()")):
        ref concrete_system = system.unsafe_get[S]()
        var context = Context[origin_of(world), *ComponentTypes](world)
        S.update[*ComponentTypes](concrete_system, context)


@fieldwise_init
struct Scheduler[*WorldComponentTypes: ComponentType]:
    comptime World = _World[*Self.WorldComponentTypes]
    comptime FunctionType = def(
        mut system: UnsafeBox, mut world: Self.World
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
                system_info[Self._update_index](
                    system_info[Self._system_index], self.world
                )
        frame_mark()


def main() raises:
    comptime if not has_accelerator():
        print("No compatible GPU found")
    else:
        var scheduler = Scheduler[Position, Velocity, Name]()
        scheduler.add_system(Move())
        scheduler.update()

        var positions_x = scheduler.world.device.enqueue_create_host_buffer[
            float_dtype
        ](entity_count)
        var positions_y = scheduler.world.device.enqueue_create_host_buffer[
            float_dtype
        ](entity_count)
        scheduler.world.device.enqueue_copy(
            positions_x, scheduler.world.position_x
        )
        scheduler.world.device.enqueue_copy(
            positions_y, scheduler.world.position_y
        )
        scheduler.world.device.synchronize()
        print(
            t"CPU position[0] ="
            t" ({ scheduler.world.host_position_x.unsafe_ptr()[unsafe_offset=0] },"
            t" { scheduler.world.host_position_y.unsafe_ptr()[unsafe_offset=0] })"
        )
        print(t"GPU position[0] = ({ positions_x[0] }, { positions_y[0] })")
