from larecs.bitmask import BitMask
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


@fieldwise_init
struct _World[*WorldTs: ComponentType]:
    comptime component_manager = ComponentManager[*Self.WorldTs]


struct EntityAccessor(Copyable):
    var id: Int

    def __init__(out self, id: Int):
        self.id = id

    def get[T: ComponentType](self) -> T:
        comptime if T == Position:
            return rebind_var[T](Position(x=1.0, y=-1.0))
        elif T == Velocity:
            return rebind_var[T](Velocity(dx=1.0, dy=-1.0))
        else:
            return rebind_var[T](Name(name=String(self.id)))


struct EntityAccessorIterator(Iterator, Movable):
    comptime Element = EntityAccessor

    var elems: List[EntityAccessor]
    var idx: Int

    def __init__(out self):
        self.elems = [
            EntityAccessor(id=1),
            EntityAccessor(id=2),
            EntityAccessor(id=3),
            EntityAccessor(id=4),
            EntityAccessor(id=5),
        ]
        self.idx = 0

    def __iter__(deinit self) -> Self:
        return self^

    def __next__(
        mut self,
    ) raises StopIteration -> Self.Element:
        if self.idx >= len(self.elems):
            raise StopIteration()
        ref result = self.elems[self.idx]
        self.idx += 1
        return result.copy()


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
struct KernelContext:
    def __iter__(self) -> EntityAccessorIterator:
        return EntityAccessorIterator()


@fieldwise_init
struct Context[*WorldTs: ComponentType]:
    comptime filter = Filter[]

    def run[
        KernelFunc: def(KernelContext) -> None,
        //,
        filter: Filter,
    ](self, kernel_func: KernelFunc):
        kernel_func(KernelContext())


trait System(Copyable, Deinitable):
    def update[*WorldTs: ComponentType](self, context: Context[*WorldTs]):
        ...


comptime World = _World[Position, Velocity, Name]


@fieldwise_init
struct Move(System):
    def update[*WorldTs: ComponentType](self, context: Context[*WorldTs]):
        def calc_new_position(context: KernelContext):
            for entity in context:
                ref pos = entity.get[Position]()
                ref vel = entity.get[Velocity]()
                pos.x += vel.dx
                pos.y += vel.dy

        context.run[context.filter.include[Position, Velocity]()](
            calc_new_position
        )

        def log_name(context: KernelContext):
            for entity in context:
                ref pos = entity.get[Position]()  # MUST fail!
                ref name = entity.get[Name]()

                print(t"Entity named {name.name}")

        context.run[context.filter.include[Name]()](log_name)


def _update_system[
    S: System, *ComponentTypes: ComponentType
](mut system: UnsafeBox, context: Context[*ComponentTypes]) raises:
    """Updates the system with the given world.

    Parameters:
        S: The type of the system.
        ComponentTypes: The types of the components in the world.

    Args:
        system: The system to update.
        context: The context to use for the update.
    """
    with Zone(function_name=String(t"{reflect[S].name()}.update()")):
        ref concrete_system = system.unsafe_get[S]()
        S.update[*ComponentTypes](concrete_system, context)


@fieldwise_init
struct Scheduler[*WorldComponentTypes: ComponentType]:
    comptime World = _World[*Self.WorldComponentTypes]

    comptime FunctionType = def(
        mut system: UnsafeBox, context: Context[*Self.WorldComponentTypes]
    ) thin raises
    """The type of system functions."""

    comptime _system_index = 0
    """The index of the system in the systems storage."""

    comptime _update_index = 1
    """The index of the update function in the systems storage."""

    var world: Self.World
    """The world updated by the scheduler."""
    var _systems: List[Tuple[UnsafeBox, Self.FunctionType]]
    """Registered systems with their lifecycle function adapters."""

    def __init__(out self, var world: Self.World):
        """
        Initializes the scheduler with a given world.

        Args:
            world: The world to use.
        """
        with Zone(function_name="Scheduler.__init__(var world: Self.World)"):
            self._systems = List[
                Tuple[
                    UnsafeBox,
                    Self.FunctionType,
                ]
            ]()
            self.world = world^

    def add_system[S: System](mut self, var system: S):
        """Adds a system to the scheduler.

        Args:
            system: The system to add.
        """
        with Zone(
            function_name="Scheduler.add_system[S: System](var system: S)"
        ):
            self._systems.append(
                (
                    UnsafeBox(system^),
                    _update_system[S, *Self.WorldComponentTypes],
                )
            )

    def update(mut self, steps: Int = 1) raises:
        """Updates all systems in the scheduler repeatedly.

        Args:
            steps: How often the systems should be updated.
        """
        with Zone(function_name="Scheduler.update(steps: Int)"):
            for _ in range(steps):
                for ref system_info in self._systems:
                    system_info[Self._update_index](
                        system_info[Self._system_index],
                        Context[*Self.WorldComponentTypes](),
                    )
        frame_mark()

    def run(mut self, steps: Int) raises:
        """Runs the scheduler for a given number of steps.

        This is the main entry point for running the scheduler.
        It calls the `initialize`, `update`, and `finalize` methods in order.
        The `update` method is called `steps` times.
        The `initialize` method is called once at the beginning, and the
        `finalize` method is called once at the end.

        Args:
            steps: The number of steps to run.
        """
        with Zone(function_name="Scheduler.run(steps: Int)"):
            self.update(steps)


def main() raises:
    scheduler = Scheduler(World())
    scheduler.add_system(Move())
    scheduler.run(1)
