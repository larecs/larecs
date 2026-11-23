"""Borrows host-local values lexically during particle movement."""

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


# region closure
@fieldwise_init
struct Move(System):
    """Counts particles through a sequential host closure."""

    def update(mut self, mut context: SystemContext[...]) raises:
        """Moves the particles and observes a synchronous captured result.

        Args:
            context: Access to the particle world.

        Raises:
            Error: If resources, execution, or the visit check fail.
        """
        var scale: Float32 = 2
        var visits = 0

        def move(
            rows: KernelContext[
                Filter().include[Position]().read[Velocity](),
                Resources().read[Time](),
            ]
        ) {imm scale, mut visits}:
            """Moves each row and counts it through a host borrow.

            Args:
                rows: One matching physical store's rows and time.
            """
            ref time = rows.resources.get[Time]()
            for particle in rows:
                ref position = particle.get[Position]()
                ref velocity = particle.get[Velocity]()
                position.x += velocity.dx * time.delta * scale
                position.y += velocity.dy * time.delta * scale
                visits += 1

        context.run(move)
        assert_equal(visits, 2)


# endregion closure
# region check
def main() raises:
    """Checks the closure across two matching physical stores.

    Raises:
        Error: If setup, execution, or a position check fails.
    """
    var world = World[Position, Velocity, Int32]()
    world.resources.add(Time(0.25))
    var walker = world.storage.add_entity(Position(0, 0), Velocity(1, 0))
    var climber = world.storage.add_entity(
        Position(5, 0), Velocity(0, 2), Int32(1)
    )
    var scheduler = Scheduler[Position, Velocity, Int32](world^)
    scheduler.add_system(Move())
    scheduler.run(steps=1)
    assert_almost_equal(scheduler.world.storage.read[Position](walker).x, 0.5)
    assert_almost_equal(scheduler.world.storage.read[Position](climber).y, 1.0)
    print("PASS: lexical host captures across two stores")


# endregion check
