"""Measures complete host particle steps after checking their results."""

from larecs import ComponentType, ResourceType

from std.testing import assert_almost_equal, assert_equal
from larecs import (
    ExecutionBackend,
    Filter,
    KernelContext,
    Resources,
    Scheduler,
    System,
    SystemContext,
    World,
)
from std.time import perf_counter_ns
from tracy import Zone


# region model
@fieldwise_init
struct Position(ComponentType, TrivialRegisterPassable):
    """Particle coordinates, using device-compatible scalar arithmetic."""

    var x: Float32
    var y: Float32


@fieldwise_init
struct Velocity(ComponentType, TrivialRegisterPassable):
    """Particle displacement per unit of simulated time."""

    var dx: Float32
    var dy: Float32


@fieldwise_init
struct Time(ResourceType):
    """Shared simulated step length."""

    var delta: Float32


# endregion model


# region kernel
comptime move_filter = Filter().include[Position]().read[Velocity]()
comptime move_resources = Resources().read[Time]()


def move(context: KernelContext[move_filter, move_resources]):
    """Moves each row using its velocity and the shared step length.

    Args:
        context: Matching rows and read-only time.
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
    """Provides a named application zone around the movement invocation."""

    def update(mut self, mut context: SystemContext[...]) raises:
        """Runs one synchronous kernel inside a Tracy zone.

        Args:
            context: Access to the simulation world.

        Raises:
            Error: If resource preparation or execution fails.
        """
        with Zone("particles.Move"):
            context.run[move]()


# endregion system
# region measurement
def main() raises:
    """Warms the simulation, times complete updates, and checks equal work.

    Raises:
        Error: If setup, stepping, or the final correctness check fails.
    """
    var scheduler = Scheduler[Position, Velocity]()
    scheduler.world.resources.add(Time(0.25))
    _ = scheduler.world.storage.add_entities(
        Position(0, 0), Velocity(1, 2), count=4097
    )
    scheduler.add_system(Move())
    scheduler.initialize()
    scheduler.update(steps=5)  # warmup is outside the measured interval
    var start = perf_counter_ns()
    with Zone("particles.complete_steps"):
        scheduler.update(steps=20)
    var elapsed = perf_counter_ns() - start
    scheduler.finalize()
    # Validation and output are outside the timer.
    var count = 0
    for particle in scheduler.world.storage.query[move_filter]():
        assert_almost_equal(particle.get[Position]().x, 6.25)
        assert_almost_equal(particle.get[Position]().y, 12.5)
        count += 1
    assert_equal(count, 4097)
    print("PASS: 4097 particles after 25 steps")
    print("Measured 20 complete host steps (ns):", elapsed)


# endregion measurement
