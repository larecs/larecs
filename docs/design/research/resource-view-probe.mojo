"""Probe portable resource descriptors using manual storage and transfer binding.

Run with `pixi run mojo run -I src docs/design/research/resource-view-probe.mojo`.
This is research evidence, not a resource adapter API. Requires a working GPU;
build without debug info because of the documented Apple compiler issue.
"""

from std.sys import has_accelerator
from std.testing import assert_equal, assert_true
from larecs import World, SystemContext, KernelContext, Filter, Resources
from larecs.resource import constrain_device_safe_resources


@fieldwise_init
struct Samples(Copyable, Movable):
    var values: List[Int32]


@fieldwise_init
struct SamplesView(Copyable, TrivialRegisterPassable):
    var values: Pointer[Int32, ImmUntrackedOrigin]
    var width: Int
    var height: Int

    def last(self) -> Int32:
        """Reads the last sample in a nonempty rectangular grid.

        Returns:
            The sample at `width * height - 1`.
        """
        return self.values[unsafe_offset=self.width * self.height - 1]


def sample_kernel(
    context: KernelContext[Filter().include[Int32](), Resources[SamplesView]()]
):
    """Adds the last sample to each selected component on either target.

    Args:
        context: Matching components and a manually bound sample descriptor.
    """
    var sample = context.resources.get[SamplesView]().last()
    for entity in context:
        entity.get[Int32]() += sample


def check_components(mut world: World[Int32], expected: Int32) raises:
    """Checks every component after synchronous execution.

    Args:
        world: World whose components should all match.
        expected: Required component value.

    Raises:
        Error: If any component differs.
    """
    var count = 0
    for entity in world.storage.query[Filter().include[Int32]()]():
        assert_equal(entity.get[Int32](), expected)
        count += 1
    assert_equal(count, 37)


def main() raises:
    """Checks one descriptor and kernel on host, GPU, then host again.

    Raises:
        Error: If GPU execution is unavailable or a result differs.
    """
    comptime assert has_accelerator(), "This probe requires GPU support"
    # Trivial movability does not establish deep-transfer safety: the locked
    # compiler accepts this List-owning resource too. Never upload Samples.
    assert_true(constrain_device_safe_resources[Samples]())
    assert_true(constrain_device_safe_resources[SamplesView]())
    var world = World[Int32]()
    if world._device_storage is None:
        raise Error("This probe requires a working GPU device context")
    var values: List[Int32] = [1, 2, 3, 9]
    world.resources.add(Samples(values^))
    var host_address = Int(world.resources.get[Samples]().values.unsafe_ptr())
    world.resources.add(
        SamplesView(
            Pointer[Int32, ImmUntrackedOrigin](
                unsafe_from_address=host_address
            ),
            2,
            2,
        )
    )
    _ = world.storage.add_entities(Int32(1), count=37)
    var context = SystemContext(world)
    context.run[sample_kernel]()
    check_components(world, 10)

    # Manual relocation proves the representation only. A production binding
    # must own this buffer and keep the source/descriptor alive even on failure.
    var device_context = world._device_storage[]._device_context
    var buffer = device_context.enqueue_create_buffer[DType.int32](4)
    try:
        buffer.enqueue_copy_from(
            Pointer[Int32, ImmUntrackedOrigin](unsafe_from_address=host_address)
        )
        var device_address = Int(buffer.device_ptr().buffer().unsafe_ptr())
        world.resources.set(
            SamplesView(
                Pointer[Int32, ImmUntrackedOrigin](
                    unsafe_from_address=device_address
                ),
                2,
                2,
            )
        )
        context.run[sample_kernel, on_device=True]()
        check_components(world, 19)
    finally:
        device_context.synchronize()
        # The current executor downloads even a read-only descriptor. Restore
        # its host pointer before allowing any subsequent host execution.
        world.resources.set(
            SamplesView(
                Pointer[Int32, ImmUntrackedOrigin](
                    unsafe_from_address=host_address
                ),
                2,
                2,
            )
        )
    context.run[sample_kernel]()
    check_components(world, 28)
    assert_equal(world.resources.get[Samples]().values[3], 9)
    # Keep the device allocation visibly live through completion.
    assert_equal(len(buffer), 4)
    print(
        "PASS: identical resource view and KernelContext kernel on"
        " host/GPU/host"
    )
