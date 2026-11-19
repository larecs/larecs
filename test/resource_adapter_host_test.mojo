"""Host-only adapter checks run with AddressSanitizer and debug information."""

from std.testing import *
from larecs import (
    World,
    SystemContext,
    Filter,
    Resources,
    KernelContext,
    BufferResource,
    ResourceType,
)

comptime Samples = BufferResource[DType.int32]
comptime spec = Resources().read[Samples]()


@fieldwise_init
struct Plain(ResourceType):
    var value: Int32


def test_host_view_and_closure_lifetime() raises:
    """Retains descriptors and host samples across multiple closure callbacks.

    Raises:
        Error: If view type, descriptor lifetime, or current source checks fail.
    """
    var world = World[Int32, Float32]()
    world.resources.add(Samples([Int32(7), Int32(8)]))
    for _ in range(17):
        _ = world.storage.add_entity(Int32(1))
    for _ in range(19):
        _ = world.storage.add_entity(Int32(1), Float32(0))
    var calls = 0

    def kernel(
        context: KernelContext[Filter().include[Int32](), spec]
    ) {mut calls}:
        """Reads the same portable descriptor in each matching host archetype.

        Args:
            context: Matching rows and the source-oriented sample view.
        """
        ref samples = context.resources.get[Samples]()
        comptime assert type_of(samples) == Samples.KernelView
        for entity in context:
            entity.get[Int32]() += samples[1]
        calls += 1

    var context = SystemContext(world)
    context.run(kernel)
    assert_equal(calls, 2)
    world.resources.get[Samples]() = Samples([Int32(3), Int32(4)])
    context.run(kernel)
    for entity in world.storage.query[Filter().include[Int32]()]():
        assert_equal(entity.get[Int32](), 13)
    assert_equal(world.resources.get[Samples]().samples[1], 4)


def test_host_write_only_set() raises:
    """Preserves set-only host write semantics for ordinary resources.

    Raises:
        Error: If the replacement fails.
    """
    var world = World[Int32]()
    world.resources.add(Plain(1))
    _ = world.storage.add_entities(Int32(0), count=1)

    def kernel(
        context: KernelContext[
            Filter().include[Int32](), Resources().write[Plain]()
        ]
    ):
        """Sets the one shared host resource without reading its old value.

        Args:
            context: One matching range and write-only resource access.
        """
        context.resources.set[Plain](Plain(9))

    var context = SystemContext(world)
    context.run[kernel]()
    assert_equal(world.resources.get[Plain]().value, 9)


def main() raises:
    """Runs host descriptor and permission checks with memory instrumentation.

    Raises:
        Error: If any test fails.
    """
    TestSuite.discover_tests[__functions_in_module()]().run()
