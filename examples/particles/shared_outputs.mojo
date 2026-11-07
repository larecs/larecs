"""Reduces per-particle outputs on one caller and checks standalone primitives."""

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
from std.atomic import Ordering
from std.testing import assert_false, assert_true
from larecs import AtomicValue, Synchronized


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
@fieldwise_init
struct Displacement(Copyable, Movable, TrivialRegisterPassable):
    """A private output for one particle, avoiding a shared kernel counter."""

    var x: Float32
    var y: Float32


comptime move_filter = Filter().include[Position]().read[Velocity]().write[
    Displacement
]()
comptime move_resources = Resources().read[Time]()


def move(context: KernelContext[move_filter, move_resources]):
    """Writes every per-row output before a later single-caller reduction.

    Args:
        context: Particle inputs and set-only displacement output.
    """
    ref time = context.resources.get[Time]()
    for particle in context:
        ref position = particle.get[Position]()
        ref velocity = particle.get[Velocity]()
        var dx = velocity.dx * time.delta
        var dy = velocity.dy * time.delta
        position.x += dx
        position.y += dy
        particle.set(Displacement(dx, dy))


# endregion kernel
# region reduction
@fieldwise_init
struct Move(System):
    """Runs row work before a single-caller reduction."""

    def update(mut self, mut context: SystemContext[...]) raises:
        """Reduces completed per-row outputs without a shared kernel write.

        Args:
            context: Access to the world after synchronous kernel completion.

        Raises:
            Error: If execution or the reduction check fails.
        """
        context.run[move]()
        var total = Displacement(0, 0)
        for particle in context.world[].storage.query[
            Filter().read[Displacement]()
        ]():
            ref value = particle.get[Displacement]()
            total.x += value.x
            total.y += value.y
        assert_almost_equal(total.x, 9.25)
        assert_almost_equal(total.y, 18.5)


# endregion reduction
# region primitives
def check_primitives() raises:
    """Checks target-local host primitives independently of ECS bindings.

    Raises:
        Error: If an atomic or guard check fails.
    """
    var counter = AtomicValue[UInt32](0)
    var updates = counter.write_view()
    assert_equal(updates.fetch_add(1), UInt32(0))
    var result = updates.compare_exchange(1, 5)
    assert_true(result.exchanged)
    assert_equal(result.observed, UInt32(1))
    updates.store[Ordering.RELEASE](7)
    assert_equal(updates.load[Ordering.ACQUIRE](), UInt32(7))

    var state = Synchronized[UInt32](10)
    var access = state.write_view()
    var attempt = access.try_read()
    assert_true(attempt.is_acquired())
    var reader = attempt^.take()
    assert_equal(reader.value(), UInt32(10))
    assert_false(access.try_write().is_acquired())
    reader^.release()
    var write_attempt = access.try_write()
    assert_true(write_attempt.is_acquired())
    var writer = write_attempt^.take()
    writer.value() += 5
    writer^.release()
    var read_attempt = access.try_read()
    assert_true(read_attempt.is_acquired())
    var after = read_attempt^.take()
    assert_equal(after.value(), UInt32(15))


# endregion primitives
# region check
def main() raises:
    """Checks particle reduction and standalone host primitives.

    Raises:
        Error: If setup, execution, or a check fails.
    """
    var scheduler = Scheduler[Position, Velocity, Displacement]()
    scheduler.world.resources.add(Time(0.25))
    _ = scheduler.world.storage.add_entities(
        Position(0, 0), Velocity(1, 2), Displacement(0, 0), count=37
    )
    scheduler.add_system(Move())
    scheduler.run(steps=1)
    check_primitives()
    print(
        "PASS: per-particle outputs, single-caller reduction, and host"
        " primitives"
    )


# endregion check
