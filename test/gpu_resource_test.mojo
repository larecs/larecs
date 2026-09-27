# SKIP_ASAN
# SKIP_DEBUG

# Every GPU test file needs both markers above: a `for entity in context`
# GPU kernel reliably crashes Apple's Metal compiler when compiled with
# `-g`. See "Known issues" in AGENTS.md for the full writeup.

from std.gpu import global_idx
from std.sys import has_accelerator
from std.sys.info import is_gpu
from std.testing import *

from larecs import (
    World,
    SystemContext,
    KernelContext,
    Filter,
    Resources,
    ResourceType,
)


# Required resources must be trivially movable for raw-byte transfer.
# Scale contains only an Int32 and needs no TrivialRegisterPassable conformance.
@fieldwise_init
struct Scale(ResourceType):
    var value: Int32


def scale_entities(
    context: KernelContext[Filter().include[Int32](), Resources[Scale]()]
):
    """Multiplies every matching entity's value by the `Scale` resource."""
    ref scale = context.resources.get[Scale]()
    for entity in context:
        entity.get[Int32]() *= scale.value


def test_kernel_context_required_resources_on_gpu() raises:
    """A GPU kernel can declare and read a resource via `KernelContext.resources`.
    """
    comptime if not has_accelerator():
        return

    var world = World[Int32]()
    world.resources.add(Scale(3))
    _ = world.storage.add_entities(Int32(1), count=5)

    var context = SystemContext(world)
    context.run[scale_entities, on_gpu=True]()

    var total: Int32 = 0
    for entity in world.storage.query[Filter().include[Int32]()]():
        total += entity.get[Int32]()

    assert_equal(total, 15)


def overwrite_scale(
    context: KernelContext[Filter().include[Int32](), Resources[Scale]()]
):
    """Overwrites the `Scale` resource with a fixed value.

    Only the first thread writes, avoiding concurrent resource mutation.

    Args:
        context: Matching component rows and the shared scale resource.
    """
    comptime if is_gpu():
        if global_idx.x != 0:
            return
    context.resources.get[Scale]() = Scale(42)


def test_kernel_context_resource_mutation_is_copied_back_to_host() raises:
    """A resource mutated on the GPU is copied back to host after the kernel runs.
    """
    comptime if not has_accelerator():
        return

    var world = World[Int32]()
    world.resources.add(Scale(3))
    _ = world.storage.add_entities(Int32(1), count=5)

    var context = SystemContext(world)
    context.run[overwrite_scale, on_gpu=True]()

    assert_equal(world.resources.get[Scale]().value, 42)


def update_with_local_captures(
    context: KernelContext[Filter().include[Int32](), Resources[Scale]()]
):
    """Uses closures capturing variables local to each GPU thread.

    Args:
        context: Matching integer components and the shared scale resource.
    """
    var factor = context.resources.get[Scale]().value
    var processed: Int32 = 0

    def transform(value: Int32) {imm factor, mut processed} -> Int32:
        """Transforms one component and counts this thread's processed rows.

        Args:
            value: The component value to scale.

        Returns:
            The scaled value plus this thread's processed row count.
        """
        processed += 1
        return value * factor + processed

    for entity in context:
        entity.get[Int32]() = transform(entity.get[Int32]())


def test_gpu_kernel_local_captures() raises:
    """Captures kernel-local values without borrowing host stack memory.

    Raises:
        Error: If execution fails or a component has an unexpected value.
    """
    comptime if not has_accelerator():
        return
    var world = World[Int32]()
    world.resources.add(Scale(3))
    # More than one block, with a partially populated final block.
    _ = world.storage.add_entities(Int32(2), count=37)
    var context = SystemContext(world)
    context.run[update_with_local_captures, on_gpu=True]()
    for entity in world.storage.query[Filter().include[Int32]()]():
        assert_equal(entity.get[Int32](), 7)


comptime functions = __functions_in_module()


def main() raises:
    TestSuite.discover_tests[functions]().run()
