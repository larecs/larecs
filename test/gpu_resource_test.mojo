# SKIP_ASAN
# SKIP_DEBUG

# Every GPU test file needs both markers above: a `for entity in context`
# GPU kernel reliably crashes Apple's Metal compiler when compiled with
# `-g`. See "Known issues" in AGENTS.md for the full writeup.

from std.sys import has_accelerator
from std.testing import *

from larecs import (
    World,
    SystemContext,
    KernelContext,
    Filter,
    Resources,
    ResourceType,
)


# `TrivialRegisterPassable` satisfies `GPUResourceType` (see
# resource.mojo): `SystemContext.run(..., on_gpu=True)` moves required
# resources as raw bytes, which is only compile-time-permitted for a type
# with no non-trivial state. `Int32`, this file's component type, is
# already `TrivialRegisterPassable` as a builtin scalar.
@fieldwise_init
struct Scale(ResourceType, TrivialRegisterPassable):
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

    Every thread writes the same value, so the result is deterministic
    regardless of which thread's write lands last.
    """
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


comptime functions = __functions_in_module()


def main() raises:
    TestSuite.discover_tests[functions]().run()
