# SKIP_ASAN
# SKIP_DEBUG

# The `-g` in `SKIP_DEBUG` above is load-bearing, not cosmetic: compiling a
# `for entity in context` GPU kernel (`KernelContext`'s `EntityAccessorIterator`,
# which lowers to `raise StopIteration()`-driven control flow) with debug info
# reliably crashes Apple's AGX Metal compiler backend (`MTLCompilerService`
# SIGABRTs inside `llvm::report_fatal_error`, surfacing here as
# `XPC_ERROR_CONNECTION_INTERRUPTED`). The same kernel compiles and runs
# correctly without `-g`. See "Known issues" in AGENTS.md for the full
# writeup and reproduction notes.

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
    """A GPU kernel can declare and read a resource via `KernelContext.resources`."""
    comptime if not has_accelerator():
        return

    var world = World[Int32]()
    world.resources.add(Scale(3))
    _ = world.storage.add_entities(Int32(1), count=5)

    var context = SystemContext(world)
    context.run[scale_entities, on_gpu=True]()

    var total: Int32 = 0
    for entity in world.storage.query[Int32]():
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
