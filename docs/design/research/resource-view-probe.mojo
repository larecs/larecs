"""Integrated scientific-grid probe for decision 0018.

Run with `pixi run mojo run -I src docs/design/research/resource-view-probe.mojo`.
Requires a working GPU; build without debug info on Apple Metal.
"""

from std.sys import has_accelerator
from std.testing import assert_equal, assert_false
from larecs import (
    World,
    SystemContext,
    KernelContext,
    Filter,
    Resources,
    DevicePassableResource,
    ResourceAdapter,
    ResourceDeviceCache,
)
from larecs.resource import constrain_device_safe_resources


@fieldwise_init
struct Samples(DevicePassableResource):
    """Owns current host samples and grid metadata."""

    comptime Adapter = SamplesAdapter
    var values: List[Int32]
    var width: Int
    var height: Int


@fieldwise_init
struct SamplesView(TrivialRegisterPassable):
    """Portable read-only descriptor over current target-local samples."""

    var values: Pointer[Int32, ImmUntrackedOrigin]
    var width: Int
    var height: Int

    def last(self) -> Int32:
        """Reads the last sample of this validated nonempty grid.

        Returns:
            Last grid sample.
        """
        return self.values[unsafe_offset=self.width * self.height - 1]


struct SamplesAdapter(ResourceAdapter):
    """Stateless adapter using current dimensions and cached sample capacity."""

    comptime Source = Samples
    comptime View[mut: Bool] = SamplesView

    @staticmethod
    def validate(source: Self.Source) raises:
        """Checks a nonempty rectangular grid before preparing either target.

        Args:
            source: Current host owner.

        Raises:
            Error: If dimensions overflow or do not match sample storage.
        """
        if source.width <= 0 or source.height <= 0:
            raise Error("This grid requires positive dimensions")
        if source.width > 9223372036854775807 // source.height:
            raise Error("Grid dimensions overflow")
        if source.width * source.height != len(source.values):
            raise Error("Grid dimensions must match sample count")

    @staticmethod
    def bind_host(source: Self.Source) raises -> Self.View[False]:
        """Borrows immutable samples from the validated host owner.

        Args:
            source: Current validated source.

        Raises:
            Error: If descriptor preparation fails.

        Returns:
            Descriptor over host samples.
        """
        return {
            Pointer[Int32, ImmUntrackedOrigin](
                unsafe_from_address=Int(source.values.unsafe_ptr())
            ),
            source.width,
            source.height,
        }

    @staticmethod
    def prepare_device(
        source: Self.Source, mut cache: ResourceDeviceCache
    ) raises -> Self.View[False]:
        """Uploads current samples and returns the same descriptor type.

        Args:
            source: Current validated source.
            cache: Source-type, context-local allocation cache.

        Raises:
            Error: If sample allocation or upload fails.

        Returns:
            Descriptor over device samples.
        """
        return {
            cache.upload[Int32](0, Span(source.values)),
            source.width,
            source.height,
        }


comptime required = Resources().read[Samples]()


def sample_kernel(context: KernelContext[Filter().include[Int32](), required]):
    """Adds the last sample through the source-oriented getter on either target.

    Args:
        context: Matching component rows and the portable grid view.
    """
    var sample = context.resources.get[Samples]().last()
    for entity in context:
        entity.get[Int32]() += sample


def check_components(mut world: World[Int32], expected: Int32) raises:
    """Checks every component after synchronous execution.

    Args:
        world: Authoritative host world.
        expected: Required component value.

    Raises:
        Error: If a component differs or row count is incorrect.
    """
    var count = 0
    for entity in world.storage.query[Filter().include[Int32]()]():
        assert_equal(entity.get[Int32](), expected)
        count += 1
    assert_equal(count, 37)


def main() raises:
    """Checks automatic registration and one kernel on host, GPU, then host.

    Raises:
        Error: If GPU execution is unavailable or a result differs.
    """
    comptime assert has_accelerator(), "This probe requires GPU support"
    assert_false(constrain_device_safe_resources[Samples]())
    assert_false(constrain_device_safe_resources[SamplesView]())
    var world = World[Int32]()
    world.resources.add(Samples([Int32(1), Int32(2), Int32(3), Int32(9)], 2, 2))
    _ = world.storage.add_entities(Int32(1), count=37)
    var context = SystemContext(world)
    context.run[sample_kernel]()
    check_components(world, 10)
    context.run[sample_kernel, on_device=True]()
    check_components(world, 19)
    context.run[sample_kernel]()
    check_components(world, 28)
    assert_equal(world.resources.get[Samples]().values[3], 9)
    print("PASS: source-oriented grid view and identical host/GPU/host kernel")
