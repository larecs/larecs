"""Checks particle results with default transfers and opt-in copy reuse."""

# SKIP_DEBUG
# SKIP_ASAN

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
struct Move[backend: ExecutionBackend](System):
    """Keeps the movement kernel and target independent of copy policy."""

    def update(mut self, mut context: SystemContext[...]) raises:
        """Completes movement and eager copy-back.

        Args:
            context: Access to the simulation world.

        Raises:
            Error: If preparation or execution fails.
        """
        context.run[move, backend=Self.backend]()


# endregion system
# region sequence
def run_stage[backend: ExecutionBackend](reuse: Bool) raises -> Position:
    """Runs a mutation sequence under one transfer policy.

    Parameters:
        backend: Explicit execution target.

    Args:
        reuse: Whether unchanged device copies may skip uploads.

    Raises:
        Error: If execution or the expected coordinates disagree.

    Returns:
        A snapshot of the walker's final position.
    """
    var world = World[Position, Velocity]()
    world.resources.add(Time(0.25))
    var walker = world.storage.add_entity(Position(0, 0), Velocity(1, 2))
    world.reuse_device_copies(reuse)
    var scheduler = Scheduler[Position, Velocity](world^)
    scheduler.add_system(Move[backend]())
    scheduler.initialize()
    scheduler.update(steps=1)  # x = 0.25
    _ = scheduler.world.resources.read[Time]().delta
    _ = scheduler.world.storage.read[Velocity](walker).dx
    scheduler.update(steps=1)  # x = 0.5; read calls preserve reuse
    scheduler.world.resources.get[Time]().delta = 0.5
    scheduler.update(steps=1)  # x = 1.0; get advances the resource revision

    # This pointer survives a later run; subsequent writes bypass tracking.
    var time_ptr = Pointer(to=scheduler.world.resources.get[Time]())
    scheduler.update(steps=1)  # x = 1.5
    time_ptr[].delta = 1.0
    scheduler.world.resources.invalidate_device[Time]()
    scheduler.update(steps=1)  # x = 2.5; explicit invalidation refreshes Time
    scheduler.world.storage.get[Velocity](walker).dx = 2
    scheduler.update(
        steps=1
    )  # x = 4.5; component get advances its column revision
    scheduler.finalize()
    var result = scheduler.world.storage.read[Position](walker).copy()
    assert_almost_equal(result.x, 4.5)
    assert_almost_equal(result.y, 7.0)
    scheduler.world.reuse_device_copies(False)
    return result


# endregion sequence
# region check
def main() raises:
    """Checks the same sequence on host, default device, and reused device copies.

    Raises:
        Error: If a target or transfer policy changes the result.
    """
    var host = run_stage[ExecutionBackend.HOST](False)
    print("PASS: host mutation/invalidation sequence")
    comptime if has_accelerator():
        var default = run_stage[ExecutionBackend.DEVICE](False)
        var reused = run_stage[ExecutionBackend.DEVICE](True)
        assert_equal(reused.x, default.x)
        assert_equal(reused.y, default.y)
        assert_equal(reused.x, host.x)
        assert_equal(reused.y, host.y)
        print("PASS: actual device default/reused copies and host parity")
    else:
        print("SKIP: device-copy reuse (no accelerator compilation support)")


# endregion check
