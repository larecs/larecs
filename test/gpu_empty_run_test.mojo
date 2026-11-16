# SKIP_ASAN
# SKIP_DEBUG

from std.gpu import global_idx
from std.sys import has_accelerator
from std.sys.info import is_gpu
from std.testing import *

from larecs import (
    Filter,
    KernelContext,
    Resources,
    ResourceType,
    SystemContext,
    World,
)


@fieldwise_init
struct Marker(ResourceType, TrivialRegisterPassable):
    var value: Int32


@fieldwise_init
struct Required(ResourceType, TrivialRegisterPassable):
    var value: Int32


def touch[
    filter: Filter
](context: KernelContext[filter, Resources[Marker, Required]()],):
    """Records launches even when the row iterator is empty.

    Parameters:
        filter: The component access mode and exclusions to exercise.

    Args:
        context: Component rows and the launch marker resources.
    """
    comptime if is_gpu():
        if global_idx.x == 0:
            context.resources.get[Marker]().value = context.resources.get[
                Required
            ]().value
    for entity in context:
        comptime if filter.writes[Float32]:
            entity.set[Float32](9.0)
        else:
            _ = entity.get[Float32]()


def check_empty_lifecycle[filter: Filter]() raises:
    """Checks empty, excluded, drained, and repopulated GPU runs.

    Parameters:
        filter: A Float32 access mode excluding Int32 entities.

    Raises:
        Error: If a run fails or an assertion detects unexpected GPU work.
    """
    comptime if not has_accelerator():
        return

    var world = World[Float32, Int32]()
    world.resources.add(Marker(7), Required(42))
    var context = SystemContext(world)

    # Neither readable nor write-only columns should be initialized.
    context.run[touch[filter], on_device=True]()
    assert_false(world._device_storage[].has_component[Float32]())
    assert_equal(world.resources.get[Marker]().value, 7)

    var excluded = world.storage.add_entity(Float32(3), Int32(1))
    context.run[touch[filter], on_device=True]()
    world._device_storage[].synchronize()
    assert_false(world._device_storage[].has_component[Float32]())
    assert_equal(world.storage.get[Float32](excluded), 3.0)
    assert_equal(world.resources.get[Marker]().value, 7)

    var matching = world.storage.add_entity(Float32(2))
    context.run[touch[filter], on_device=True]()
    assert_true(world._device_storage[].has_component[Float32]())
    assert_equal(world.resources.get[Marker]().value, 42)
    comptime if filter.writes[Float32]:
        assert_equal(world.storage.get[Float32](matching), 9.0)
    else:
        assert_equal(world.storage.get[Float32](matching), 2.0)

    world.storage.remove_entity(matching)
    world.storage.remove_entity(excluded)
    world.resources.get[Marker]().value = 7
    # Repeat with a previously allocated column and an empty archetype.
    for _ in range(2):
        context.run[touch[filter], on_device=True]()
        world._device_storage[].synchronize()
        assert_equal(world.resources.get[Marker]().value, 7)

    _ = world.storage.add_entity(Float32(5))
    context.run[touch[filter], on_device=True]()
    assert_equal(world.resources.get[Marker]().value, 42)


def test_gpu_empty_include_lifecycle() raises:
    """Checks empty GPU runs with read/write access.

    Raises:
        Error: If a lifecycle check fails.
    """
    check_empty_lifecycle[Filter().include[Float32]().exclude[Int32]()]()


def test_gpu_empty_read_lifecycle() raises:
    """Checks empty GPU runs with read-only access.

    Raises:
        Error: If a lifecycle check fails.
    """
    check_empty_lifecycle[Filter().read[Float32]().exclude[Int32]()]()


def test_gpu_empty_write_lifecycle() raises:
    """Checks empty GPU runs with write-only access.

    Raises:
        Error: If a lifecycle check fails.
    """
    check_empty_lifecycle[Filter().write[Float32]().exclude[Int32]()]()


def include_float(context: KernelContext[Filter().include[Float32]()]):
    """Updates Float32 rows for the original fresh-world reproducer.

    Args:
        context: The Float32 rows to update.
    """
    for entity in context:
        entity.get[Float32]() += 1


def test_gpu_fresh_empty_float_world() raises:
    """Runs the issue's exact fresh World[Float32] reproducer.

    Raises:
        Error: If an empty run fails or creates a column.
    """
    comptime if not has_accelerator():
        return
    var world = World[Float32]()
    var context = SystemContext(world)
    context.run[include_float, on_device=True]()
    assert_false(world._device_storage[].has_component[Float32]())


def test_gpu_empty_run_validates_resources_and_device() raises:
    """Preserves device-first validation and missing-resource errors.

    Raises:
        Error: If validation or the subsequent valid run fails.
    """
    comptime if not has_accelerator():
        return
    var world = World[Float32]()
    world.resources.add(Marker(7))
    var context = SystemContext(world)
    var raised = False
    try:
        context.run[touch[Filter().include[Float32]()], on_device=True]()
    except e:
        raised = True
        assert_equal(
            String(e),
            String(
                t"The resource `{reflect[Required].name()}` does not exist."
            ),
        )
    assert_true(raised)
    assert_false(world._device_storage[].has_component[Float32]())
    assert_equal(world.resources.get[Marker]().value, 7)

    world.resources.add(Required(42))
    context.run[touch[Filter().include[Float32]()], on_device=True]()
    world._device_storage[].synchronize()
    assert_equal(world.resources.get[Marker]().value, 7)

    world._device_storage = None
    world.resources.remove[Required]()
    raised = False
    try:
        context.run[touch[Filter().include[Float32]()], on_device=True]()
    except e:
        raised = True
        assert_true("working device context" in String(e))
    assert_true(raised)


def test_launch_probe_compiles_for_host() raises:
    """Checks that the launch probe can instantiate without device primitives.

    Raises:
        Error: If host dispatch fails or changes the device-only marker.
    """
    var world = World[Float32]()
    world.resources.add(Marker(7), Required(42))
    var entity = world.storage.add_entity(Float32(2))
    var context = SystemContext(world)
    context.run[touch[Filter().include[Float32]()]]()
    assert_equal(world.storage.get[Float32](entity), 9.0)
    assert_equal(world.resources.get[Marker]().value, 7)


# An explicit list avoids a compiler crash reflecting the generic GPU helper.
comptime functions = (
    test_launch_probe_compiles_for_host,
    test_gpu_empty_include_lifecycle,
    test_gpu_empty_read_lifecycle,
    test_gpu_empty_write_lifecycle,
    test_gpu_fresh_empty_float_world,
    test_gpu_empty_run_validates_resources_and_device,
)


def main() raises:
    """Runs the empty GPU dispatch regression suite.

    Raises:
        Error: If a regression test fails.
    """
    TestSuite.discover_tests[functions]().run()
