# SKIP_ASAN

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


comptime functions = __functions_in_module()


def main() raises:
    TestSuite.discover_tests[functions]().run()
