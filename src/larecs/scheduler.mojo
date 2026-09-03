"""Execution of systems against a world.

Provides `Scheduler`, which owns a world and runs registered [..system.System]
implementations through their initialize/update/finalize lifecycle.
"""

from .component import ComponentType
from .resource import ResourceStorage
from .world import World
from .system import (
    System,
    SystemContext,
    _initialize_system,
    _update_system,
    _finalize_system,
)
from .unsafe_box import UnsafeBox

from std.reflection import reflect
from tracy import Zone, frame_mark


struct Scheduler[*ComponentTypes: ComponentType](Movable):
    """
    Manages the execution of systems in a world.

    The systems must implement [..system.System].
    Usage example:

    Example:

    ```mojo {doctest="scheduler" global=true hide=true}
    from larecs import World, Scheduler, System, SystemContext

    @fieldwise_init
    struct Position(Copyable, Movable):
        var x: Float64
        var y: Float64

    @fieldwise_init
    struct Velocity(Copyable, Movable):
        var x: Float64
        var y: Float64
    ```

    ```mojo {doctest="scheduler" global=true}
    @fieldwise_init
    struct MySystem(System):
        var internal_variable: Int

        # This is executed once at the beginning
        def initialize(mut self, mut context: SystemContext[...]) raises:
            _ = context.world[].storage.add_entities(
                Position(0.0, 0.0), Velocity(1.0, 1.0), count=10
            )

        # This is executed in each step
        def update(mut self, mut context: SystemContext[...]) raises:
            for entity in context.world[].storage.query[Position, Velocity]():
                entity.get[Position]().x += entity.get[Velocity]().x
                entity.get[Position]().y += entity.get[Velocity]().y

        # This is executed at the end
        def finalize(mut self, mut context: SystemContext[...]) raises:
            print("Final positions")
            for entity in context.world[].storage.query[Position]():
                print(entity.get[Position]().x, entity.get[Position]().y)
    ```

    ```mojo {doctest="scheduler"}
    scheduler = Scheduler[Position, Velocity]()
    scheduler.add_system(MySystem(internal_variable=42))
    scheduler.run(10)
    ```

    Parameters:
        ComponentTypes: A variadic list with all possible component types for the world.
    """

    comptime World = World[*Self.ComponentTypes]
    """The world type used by the scheduler."""

    comptime SystemContext = SystemContext[
        MutUntrackedOrigin, *Self.ComponentTypes
    ]
    """The system context type used by the scheduler.

    Bound to `MutUntrackedOrigin` rather than a real tracked origin: the
    scheduler owns `world` itself and stores its systems type-erased
    (`UnsafeBox` plus a fixed `FunctionType`), so there is no single borrow
    of `self` that all of `initialize`/`update`/`finalize`'s calls could
    share -- `world`'s origin is re-borrowed fresh on every call. `world` is
    a long-lived field of `Self`, never a short-lived temporary, so casting
    away its origin here is safe (unlike casting the origin of a `ref` into
    `ResourceStorage`'s Dict/`UnsafeBox`-backed entries, which is not).
    """

    comptime FunctionType = def(
        mut system: UnsafeBox, mut context: Self.SystemContext
    ) thin raises
    """The type of system functions."""

    comptime _system_index = 0
    """The index of the system in the systems storage."""

    comptime _initialize_index = 1
    """The index of the initialize function in the systems storage."""

    comptime _update_index = 2
    """The index of the update function in the systems storage."""

    comptime _finalize_index = 3
    """The index of the finalize function in the systems storage."""

    var world: Self.World
    """The world updated by the scheduler."""
    var _systems: List[
        Tuple[
            UnsafeBox, Self.FunctionType, Self.FunctionType, Self.FunctionType
        ]
    ]
    """Registered systems with their lifecycle function adapters."""

    def __init__(out self):
        """
        Initializes the scheduler, creating a new world.
        """
        with Zone(function_name="Scheduler.__init__()"):
            self._systems = List[
                Tuple[
                    UnsafeBox,
                    Self.FunctionType,
                    Self.FunctionType,
                    Self.FunctionType,
                ]
            ]()
            self.world = Self.World()

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
                    Self.FunctionType,
                    Self.FunctionType,
                ]
            ]()
            self.world = world^

    def add_system[S: System](mut self, var system: S):
        """Adds a system to the scheduler.

        Parameters:
            S: The type of the system to add.

        Args:
            system: The system to add.
        """
        with Zone(
            function_name="Scheduler.add_system[S: System](var system: S)"
        ):
            self._systems.append(
                (
                    UnsafeBox(system^),
                    _initialize_system[
                        S, MutUntrackedOrigin, *Self.ComponentTypes
                    ],
                    _update_system[S, MutUntrackedOrigin, *Self.ComponentTypes],
                    _finalize_system[
                        S, MutUntrackedOrigin, *Self.ComponentTypes
                    ],
                )
            )

    def initialize(mut self) raises:
        """Initializes all systems in the scheduler.

        Raises:
            Error: If a system's `initialize` implementation raises.
        """
        with Zone(function_name="Scheduler.initialize()"):
            var world_ptr = Pointer(to=self.world).unsafe_origin_cast[
                MutUntrackedOrigin
            ]()
            var context = Self.SystemContext(world_ptr[])
            for ref system_info in self._systems:
                system_info[Self._initialize_index](
                    system_info[Self._system_index], context
                )
        frame_mark()

    def update(mut self, steps: Int = 1) raises:
        """Updates all systems in the scheduler repeatedly.

        Args:
            steps: How often the systems should be updated.

        Raises:
            Error: If a system's `update` implementation raises.
        """
        with Zone(function_name="Scheduler.update(steps: Int)"):
            var world_ptr = Pointer(to=self.world).unsafe_origin_cast[
                MutUntrackedOrigin
            ]()
            var context = Self.SystemContext(world_ptr[])
            for _ in range(steps):
                for ref system_info in self._systems:
                    system_info[Self._update_index](
                        system_info[Self._system_index], context
                    )
        frame_mark()

    def finalize(mut self) raises:
        """Finalizes all systems in the scheduler.

        Raises:
            Error: If a system's `finalize` implementation raises.
        """
        with Zone(function_name="Scheduler.finalize()"):
            var world_ptr = Pointer(to=self.world).unsafe_origin_cast[
                MutUntrackedOrigin
            ]()
            var context = Self.SystemContext(world_ptr[])
            for ref system_info in self._systems:
                system_info[Self._finalize_index](
                    system_info[Self._system_index], context
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

        Raises:
            Error: If a system's `initialize`, `update`, or `finalize` implementation raises.
        """
        with Zone(function_name="Scheduler.run(steps: Int)"):
            self.initialize()
            self.update(steps)
            self.finalize()
