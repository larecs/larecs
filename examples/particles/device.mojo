"""Checks identical host and device particle steps without automatic fallback."""

# SKIP_DEBUG
# SKIP_ASAN

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
from std.sys import has_accelerator
from std.testing import assert_raises


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
struct Move[backend: ExecutionBackend](System):
    """Selects the execution target explicitly."""

    def update(mut self, mut context: SystemContext[...]) raises:
        """Runs one synchronous movement step.

        Args:
            context: Access to this simulation's world.

        Raises:
            Error: If resource preparation or execution fails.
        """
        context.run[move, backend=Self.backend]()


# endregion system
# region parity
def run_stage[backend: ExecutionBackend]() raises -> Position:
    """Runs two steps and checks both coordinates and an unmatched marker.

    Parameters:
        backend: Explicit target for this independent simulation.

    Raises:
        Error: If setup, execution, or a position check fails.

    Returns:
        The sum of the moving particles' final coordinates.
    """
    var world = World[Position, Velocity]()
    world.resources.add(Time(0.25))
    _ = world.storage.add_entities(Position(0, 0), Velocity(1, 2), count=37)
    var marker = world.storage.add_entity(Position(-3, -3))
    var scheduler = Scheduler[Position, Velocity](world^)
    scheduler.add_system(Move[backend]())
    scheduler.run(steps=2)
    var total = Position(0, 0)
    for particle in scheduler.world.storage.query[move_filter]():
        ref position = particle.get[Position]()
        assert_almost_equal(position.x, 0.5)
        assert_almost_equal(position.y, 1.0)
        total.x += position.x
        total.y += position.y
    assert_equal(scheduler.world.storage.read[Position](marker).x, -3)
    return total


def main() raises:
    """Reports device execution separately from a hardware skip.

    Raises:
        Error: If host checks, device execution, or parity checks fail.
    """
    var host = run_stage[ExecutionBackend.HOST]()
    assert_almost_equal(host.x, 18.5)
    assert_almost_equal(host.y, 37.0)
    print("PASS: host particle checks")
    comptime if has_accelerator():
        var device = run_stage[ExecutionBackend.DEVICE]()
        assert_almost_equal(device.x, host.x)
        assert_almost_equal(device.y, host.y)
        print("PASS: actual device execution and host/device parity")
    else:
        # A skip is an application choice; DEVICE itself never falls back.
        var empty = World[Position, Velocity]()
        empty.resources.add(Time(0.25))
        var context = SystemContext(empty)
        with assert_raises():
            context.run[move, backend=ExecutionBackend.DEVICE]()
        print("SKIP: device parity (no accelerator compilation support)")


# endregion parity
