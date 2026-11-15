"""Moves particles with constant velocities for a fixed number of steps.

This is the complete program of the "Your first simulation" tutorial.
"""

# region imports
from larecs import ComponentType, ResourceType

from std.testing import assert_almost_equal

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
struct Position(ComponentType):
    """Where a particle is."""

    var x: Float64
    """Horizontal coordinate."""
    var y: Float64
    """Vertical coordinate."""


@fieldwise_init
struct Velocity(ComponentType):
    """How far a particle moves per unit of time."""

    var dx: Float64
    """Horizontal speed."""
    var dy: Float64
    """Vertical speed."""


# endregion components


# region time
@fieldwise_init
struct Time(ResourceType):
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
    world.resources.add(Time(delta=0.1))

    var walker = world.storage.add_entity(Position(0, 0), Velocity(1, 0))
    var climber = world.storage.add_entity(Position(5, 0), Velocity(0, 2))
    var marker = world.storage.add_entity(Position(-3, -3))
    # endregion world

    # region scheduler
    var scheduler = Scheduler[Position, Velocity](world^)
    scheduler.add_system(Move())
    scheduler.run(steps=10)
    # endregion scheduler

    # region check
    ref storage = scheduler.world.storage
    assert_almost_equal(storage.get[Position](walker).x, 1.0)
    assert_almost_equal(storage.get[Position](climber).y, 2.0)
    assert_almost_equal(storage.get[Position](marker).x, -3.0)
    print("All particles reached their expected positions.")
    # endregion check
