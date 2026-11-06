"""Configures shared time before moving a growing particle simulation.

Region markers supply excerpts for the particle learning path.
"""

# region imports
from std.testing import assert_almost_equal, assert_equal

from larecs import (
    Filter,
    KernelContext,
    Resources,
    Scheduler,
    System,
    SystemContext,
    World,
)

# endregion imports


# region components
@fieldwise_init
struct Position(Copyable, Movable):
    """Where a particle is."""

    var x: Float64
    """Horizontal coordinate."""
    var y: Float64
    """Vertical coordinate."""


@fieldwise_init
struct Velocity(Copyable, Movable):
    """How far a particle moves per unit of time."""

    var dx: Float64
    """Horizontal speed."""
    var dy: Float64
    """Vertical speed."""


# endregion components


# region time
@fieldwise_init
struct Time(Copyable, Movable):
    """The simulated time that passes in one step."""

    var delta: Float64
    """Step length."""


# endregion time


# region kernel
comptime move_filter = Filter().include[Position]().read[Velocity]()
comptime move_resources = Resources().read[Time]()


def move(context: KernelContext[move_filter, move_resources]):
    """Advances every particle by its velocity times the step length.

    Args:
        context: The matching rows and the declared resources.
    """
    ref time = context.resources.get[Time]()
    for particle in context:
        ref position = particle.get[Position]()
        ref velocity = particle.get[Velocity]()
        position.x += velocity.dx * time.delta
        position.y += velocity.dy * time.delta


# endregion kernel


# region write_only
def reset_position(context: KernelContext[Filter().write[Position]()]):
    """Initializes every selected position without reading it.

    Args:
        context: Selected rows with write-only Position access.
    """
    for particle in context:
        particle.set(Position(0, 0))


# endregion write_only


# region lifecycle
@fieldwise_init
struct Spawn(System):
    """Creates and moves only the new particles at initialization."""

    def initialize(mut self, mut context: SystemContext[...]) raises:
        """Creates a scoped batch.

        Args:
            context: Access to the simulation world.

        Raises:
            Error: If creation or movement fails.
        """
        with context.add_entities(Position(0, 0), count=3) as selected:
            selected.add(Velocity(1, 0))
            selected.run[reset_position]()
            selected.run[move]()
        context.world[].storage.remove_entities[
            Filter().include[Position]().exclude[Velocity]()
        ]()

    def update(mut self, mut context: SystemContext[...]) raises:
        """Leaves creation to initialization.

        Args:
            context: Access to the simulation world.
        """
        pass


# endregion lifecycle


# region configuration
@fieldwise_init
struct Configuration(Copyable, Movable):
    """Shared configuration for subsequent movement steps."""

    var delta: Float64
    """Configured step length."""


@fieldwise_init
struct ConfigureTime(System):
    """Sets the step length before movement."""

    def update(mut self, mut context: SystemContext[...]) raises:
        """Reads configuration and updates shared time.

        Args:
            context: Access to the simulation resources.

        Raises:
            Error: If a required resource is missing.
        """
        ref resources = context.world[].resources
        resources.get[Time]().delta = resources.get[Configuration]().delta


# endregion configuration


# region system
@fieldwise_init
struct Move(System):
    """Runs the `move` kernel once per step."""

    def update(mut self, mut context: SystemContext[...]) raises:
        """Moves all particles.

        Args:
            context: Access to the scheduler's world.

        Raises:
            Error: If `Time` is missing from the world.
        """
        context.run[move]()


# endregion system


def main() raises:
    """Runs the simulation and checks the final positions.

    Raises:
        Error: If the simulation fails or a position differs from the expected value.
    """
    # region world
    var world = World[Position, Velocity]()
    world.resources.add(Time(delta=0.1), Configuration(delta=0.25))

    var walker = world.storage.add_entity(Position(0, 0), Velocity(1, 0))
    var climber = world.storage.add_entity(Position(5, 0), Velocity(0, 2))
    _ = world.storage.add_entity(Position(-3, -3))
    # endregion world

    # region scheduler
    var scheduler = Scheduler[Position, Velocity](world^)
    scheduler.add_system(Spawn())
    scheduler.add_system(ConfigureTime())
    scheduler.add_system(Move())
    scheduler.run(steps=10)
    # endregion scheduler

    # region check
    ref storage = scheduler.world.storage
    assert_almost_equal(storage.get[Position](walker).x, 2.5)
    assert_almost_equal(storage.get[Position](climber).y, 5.0)
    assert_equal(len(storage.query[Filter().include[Position]()]()), 5)
    var spawned_count = 0
    for row in storage.query[move_filter]():
        var entity = row.get_entity()
        if entity != walker and entity != climber:
            assert_almost_equal(row.get[Position]().x, 2.6)
            assert_almost_equal(row.get[Position]().y, 0.0)
            spawned_count += 1
    assert_equal(spawned_count, 3)
    print("Configured time moved walker to x=2.5 and climber to y=5.")
    # endregion check
