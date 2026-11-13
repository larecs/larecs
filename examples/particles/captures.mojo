"""Binds ordered explicit capture slots on the host and device."""

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
from std.gpu import global_idx
from std.sys.info import is_gpu
from larecs import Captures, ReadCapture, MutCapture, read_capture, mut_capture


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
comptime locals_spec = Captures[ReadCapture[Float32], MutCapture[Int32]]()


def move(context: KernelContext[move_filter, move_resources, locals_spec]):
    """Moves particles and records the processed count with a single writer.

    Args:
        context: Rows, time, and ordered scale/count capture slots.
    """
    ref time = context.resources.get[Time]()
    var scale = context.captures.get[0]()
    for particle in context:
        ref position = particle.get[Position]()
        ref velocity = particle.get[Velocity]()
        position.x += velocity.dx * time.delta * scale
        position.y += velocity.dy * time.delta * scale
    # The count is shared, not one private scalar per device thread.
    comptime if is_gpu():
        if global_idx.x != 0:
            return
    context.captures.get[1]() += context.length


# endregion kernel
# region system
@fieldwise_init
struct Move[backend: ExecutionBackend](System):
    """Binds local values for one synchronous step."""

    def update(mut self, mut context: SystemContext[...]) raises:
        """Checks count copy-back before the system returns.

        Args:
            context: Access to the simulation world.

        Raises:
            Error: If binding, execution, or the count check fails.
        """
        var scale: Float32 = 2
        var processed: Int32 = 0
        context.run[move, backend=Self.backend](
            read_capture(scale), mut_capture(processed)
        )
        assert_equal(scale, 2)
        assert_equal(processed, 37)


# endregion system
# region check
def run_stage[backend: ExecutionBackend]() raises:
    """Checks empty bindings, two physical stores, and a partial device block.

    Parameters:
        backend: Target to validate.

    Raises:
        Error: If setup, execution, or an assertion fails.
    """
    var world = World[Position, Velocity, Int32]()
    world.resources.add(Time(0.25))
    var scale: Float32 = 2
    var processed: Int32 = 9
    var empty_context = SystemContext(world)
    empty_context.run[move, backend=backend](
        read_capture(scale), mut_capture(processed)
    )
    assert_equal(processed, 9)
    _ = world.storage.add_entities(Position(0, 0), Velocity(1, 2), count=18)
    _ = world.storage.add_entities(
        Position(0, 0), Velocity(1, 2), Int32(1), count=19
    )
    var scheduler = Scheduler[Position, Velocity, Int32](world^)
    scheduler.add_system(Move[backend]())
    scheduler.run(steps=1)
    for particle in scheduler.world.storage.query[move_filter]():
        assert_almost_equal(particle.get[Position]().x, 0.5)
        assert_almost_equal(particle.get[Position]().y, 1.0)


def main() raises:
    """Always executes host checks and labels accelerator coverage explicitly.

    Raises:
        Error: If any executed target fails.
    """
    run_stage[ExecutionBackend.HOST]()
    print("PASS: explicit host captures, including empty matches")
    comptime if has_accelerator():
        run_stage[ExecutionBackend.DEVICE]()
        print("PASS: actual device captures and synchronous count copy-back")
    else:
        print("SKIP: device captures (no accelerator compilation support)")


# endregion check
