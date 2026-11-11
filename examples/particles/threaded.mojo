"""Checks threaded particle movement against sequential host results."""

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
from larecs import ThreadedExecutionConfig


# region model
@fieldwise_init
struct Position(Copyable, Movable, TrivialRegisterPassable):
    """Particle coordinates, using device-compatible scalar arithmetic."""

    var x: Float32
    var y: Float32


@fieldwise_init
struct Velocity(Copyable, Movable, TrivialRegisterPassable):
    """Particle displacement per unit of simulated time."""

    var dx: Float32
    var dy: Float32


@fieldwise_init
struct Time(Copyable, Movable):
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
struct Move[threaded: Bool](System):
    """Opts into host chunks for this movement kernel."""

    def update(mut self, mut context: SystemContext[...]) raises:
        """Moves disjoint rows and joins before returning.

        Args:
            context: Access to the simulation world.

        Raises:
            Error: If threaded eligibility or preparation fails.
        """
        context.run[move, threaded=Self.threaded]()


# endregion system
# region check
def run_stage[threaded: Bool](workers: Int) raises -> Position:
    """Checks parallel dispatch and whole-range fallback against exact values.

    Parameters:
        threaded: Whether to opt into the threaded engine.

    Args:
        workers: Submitted task budget; one exercises sequential fallback.

    Raises:
        Error: If configuration, execution, or a result check fails.

    Returns:
        Coordinate sums after two steps.
    """
    var world = World[Position, Velocity](
        execution_config=ThreadedExecutionConfig(
            workers=workers, chunks_per_worker=2, min_parallel_rows=0
        )
    )
    world.resources.add(Time(0.25))
    _ = world.storage.add_entities(Position(0, 0), Velocity(1, 2), count=4097)
    var scheduler = Scheduler[Position, Velocity](world^)
    scheduler.add_system(Move[threaded]())
    scheduler.run(steps=2)
    var total = Position(0, 0)
    for particle in scheduler.world.storage.query[move_filter]():
        ref position = particle.get[Position]()
        assert_almost_equal(position.x, 0.5)
        assert_almost_equal(position.y, 1.0)
        total.x += position.x
        total.y += position.y
    return total


def main() raises:
    """Compares the sequential, one-worker, and multi-task call paths.

    Raises:
        Error: If an execution path disagrees.
    """
    var sequential = run_stage[False](1)
    var fallback = run_stage[True](1)
    var threaded = run_stage[True](4)
    assert_equal(fallback.x, sequential.x)
    assert_equal(fallback.y, sequential.y)
    assert_equal(threaded.x, sequential.x)
    assert_equal(threaded.y, sequential.y)
    print(
        "PASS: sequential, one-worker fallback, and four-task particle parity"
    )


# endregion check
