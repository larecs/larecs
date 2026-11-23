"""Moves particles using a buffer and an adapter-backed grid."""

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
from larecs import (
    BufferResource,
    DevicePassableResource,
    ResourceAdapter,
    ResourceDeviceCache,
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


# region owner_view
comptime Samples = BufferResource[DType.float32]


@fieldwise_init
struct Grid(DevicePassableResource):
    """Owns samples and dimensions on the host."""

    comptime Adapter = GridAdapter
    var values: List[Float32]
    var width: Int
    var height: Int


@fieldwise_init
struct GridView(TrivialRegisterPassable):
    """Borrows immutable samples in the current target's address space."""

    var values: Pointer[Float32, ImmUntrackedOrigin]
    var width: Int
    var height: Int

    def last(self) -> Float32:
        """Reads the final sample of a validated nonempty grid.

        Returns:
            The bottom-right sample.
        """
        return self.values[unsafe_offset=self.width * self.height - 1]


# endregion owner_view
# region adapter
struct GridAdapter(ResourceAdapter):
    """Prepares the same immutable descriptor for either target."""

    comptime Source = Grid
    comptime View[mut: Bool] = GridView

    @staticmethod
    def validate(source: Self.Source) raises:
        """Validates shape and bounds before either target is prepared.

        Args:
            source: Current host owner.

        Raises:
            Error: If shape arithmetic overflows or sample counts disagree.
        """
        if source.width <= 0 or source.height <= 0:
            raise Error("Grid dimensions must be positive")
        if source.width > Int(Int64.MAX) // source.height:
            raise Error("Grid dimensions overflow")
        if source.width * source.height != len(source.values):
            raise Error("Grid shape must match sample count")

    @staticmethod
    def bind_host(source: Self.Source) raises -> Self.View[False]:
        """Borrows the validated owner's samples without copying.

        Args:
            source: Owner retained through invocation completion.

        Returns:
            Host-local immutable descriptor.
        """
        return {
            Pointer[Float32, ImmUntrackedOrigin](
                unsafe_from_address=Int(source.values.unsafe_ptr())
            ),
            source.width,
            source.height,
        }

    @staticmethod
    def prepare_device(
        source: Self.Source, mut cache: ResourceDeviceCache
    ) raises -> Self.View[False]:
        """Uploads samples through invocation-owned staging.

        Args:
            source: Current validated owner.
            cache: Source-type and device-context local allocations.

        Raises:
            Error: If allocation or upload fails.

        Returns:
            Descriptor containing a device-local sample pointer.
        """
        return {
            cache.upload[Float32](0, Span(source.values)),
            source.width,
            source.height,
        }


# endregion adapter
# region kernel
comptime move_filter = Filter().include[Position]().read[Velocity]()
comptime move_resources = Resources().read[Time, Samples, Grid]()


def move(context: KernelContext[move_filter, move_resources]):
    """Uses source-type lookup to read two portable views.

    Args:
        context: Particle rows, plain time, and adapted resources.
    """
    ref samples = context.resources.get[Samples]()
    ref grid = context.resources.get[Grid]()
    ref time = context.resources.get[Time]()
    var scale = samples[0] + grid.last()
    for particle in context:
        ref position = particle.get[Position]()
        ref velocity = particle.get[Velocity]()
        position.x += velocity.dx * time.delta * scale
        position.y += velocity.dy * time.delta * scale


# endregion kernel
# region check
@fieldwise_init
struct Move[backend: ExecutionBackend](System):
    """Runs movement with access-selected resource views."""

    def update(mut self, mut context: SystemContext[...]) raises:
        """Binds resources for one complete invocation.

        Args:
            context: Access to the particle world.

        Raises:
            Error: If validation, preparation, or execution fails.
        """
        context.run[move, backend=Self.backend]()


def run_stage[backend: ExecutionBackend]() raises:
    """Checks owner edits, portable reads, and invalid shape rejection.

    Parameters:
        backend: Target to validate independently.

    Raises:
        Error: If execution or an assertion fails.
    """
    var world = World[Position, Velocity]()
    world.resources.add(
        Time(0.25),
        Samples([Float32(1)]),
        Grid([Float32(0), Float32(0), Float32(0), Float32(2)], 2, 2),
    )
    var walker = world.storage.add_entity(Position(0, 0), Velocity(1, 2))
    var scheduler = Scheduler[Position, Velocity](world^)
    scheduler.add_system(Move[backend]())
    scheduler.initialize()
    scheduler.update(steps=1)
    assert_almost_equal(scheduler.world.storage.read[Position](walker).x, 0.75)
    scheduler.world.resources.get[Grid]().values[3] = 3
    scheduler.update(steps=1)
    assert_almost_equal(scheduler.world.storage.read[Position](walker).x, 1.75)
    assert_almost_equal(scheduler.world.storage.read[Position](walker).y, 3.5)
    assert_equal(scheduler.world.resources.read[Grid]().values[3], 3)
    scheduler.finalize()

    # Adapter validation also runs when no entities match.
    var empty = World[Position, Velocity]()
    empty.resources.add(
        Time(0.25), Samples([Float32(1)]), Grid(List[Float32](), 2, 2)
    )
    var context = SystemContext(empty)
    with assert_raises():
        context.run[move, backend=backend]()


def main() raises:
    """Labels executed resource targets separately from hardware skips.

    Raises:
        Error: If an executed target fails.
    """
    run_stage[ExecutionBackend.HOST]()
    print("PASS: host buffer/grid views, owner edits, and empty validation")
    comptime if has_accelerator():
        run_stage[ExecutionBackend.DEVICE]()
        print("PASS: actual device buffer/grid views and particle checks")
    else:
        print("SKIP: device resources (no accelerator compilation support)")


# endregion check
