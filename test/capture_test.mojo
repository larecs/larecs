# SKIP_ASAN
# SKIP_DEBUG

from std.sys import has_accelerator
from std.gpu import global_idx
from std.sys.info import is_gpu
from std.testing import assert_equal, TestSuite
from larecs import (
    World,
    SystemContext,
    KernelContext,
    Filter,
    Captures,
    ReadCapture,
    MutCapture,
    read_capture,
    mut_capture,
    Resources,
    ResourceType,
)


@fieldwise_init
struct CaptureBias(ResourceType):
    var value: Int32


comptime captures = Captures[ReadCapture[Int32], MutCapture[Int32]]()


def scale_and_record(
    context: KernelContext[
        Filter().include[Int32](),
        Resources[CaptureBias](),
        capture_spec=captures,
    ]
):
    """Scales matching rows and updates the mutable capture from one thread.

    Args:
        context: Component rows and the bound local values.
    """
    var factor = (
        context.captures.get[0]() + context.resources.get[CaptureBias]().value
    )
    for entity in context:
        entity.get[Int32]() *= factor
    comptime if is_gpu():
        if global_idx.x != 0:
            return
    context.captures.get[1]() += context.length


def check_capture_round_trip[on_gpu: Bool]() raises:
    """Checks read-only and copy-back bindings of the same value type.

    Parameters:
        on_gpu: Whether to execute on the GPU.

    Raises:
        Error: If execution or an assertion fails.
    """
    var world = World[Int32]()
    world.resources.add(CaptureBias(0))
    var entity = world.storage.add_entity(Int32(4))
    var factor: Int32 = 3
    var result: Int32 = 7
    var context = SystemContext(world)
    context.run[scale_and_record, on_gpu=on_gpu](
        read_capture(factor), mut_capture(result)
    )
    assert_equal(factor, 3)
    assert_equal(world.storage.get[Int32](entity), 12)
    assert_equal(result, 8)


def test_cpu_capture_bindings() raises:
    """Checks bindings on the CPU.

    Raises:
        Error: If execution or an assertion fails.
    """
    check_capture_round_trip[False]()


def test_gpu_capture_bindings() raises:
    """Checks upload and copy-back on an available accelerator.

    Raises:
        Error: If execution or an assertion fails.
    """
    comptime if has_accelerator():
        check_capture_round_trip[True]()


def check_repeated_and_empty_bindings[on_gpu: Bool]() raises:
    """Checks repeated transfers, partial GPU blocks, and multiple archetypes.

    Parameters:
        on_gpu: Whether to execute on the GPU.

    Raises:
        Error: If execution or an assertion fails.
    """
    var world = World[Int32, Float32]()
    world.resources.add(CaptureBias(1))
    var factor: Int32 = 2
    var processed: Int32 = 9
    var context = SystemContext(world)
    context.run[scale_and_record, on_gpu=on_gpu](
        read_capture(factor), mut_capture(processed)
    )
    assert_equal(processed, 9)
    # Re-borrow the world after the first context's last use.
    for i in range(37):
        if i % 2:
            _ = world.storage.add_entity(Int32(i + 1))
        else:
            _ = world.storage.add_entity(Int32(i + 1), Float32(0))
    var populated_context = SystemContext(world)
    populated_context.run[scale_and_record, on_gpu=on_gpu](
        read_capture(factor), mut_capture(processed)
    )
    assert_equal(processed, 46)
    factor = 4
    populated_context.run[scale_and_record, on_gpu=on_gpu](
        read_capture(factor), mut_capture(processed)
    )
    assert_equal(processed, 83)
    var total: Int32 = 0
    for entity in world.storage.query[Filter().include[Int32]()]():
        total += entity.get[Int32]()
    assert_equal(total, 15 * (37 * 38 // 2))


def test_cpu_repeated_and_empty_bindings() raises:
    """Checks repeated and empty CPU invocations.

    Raises:
        Error: If execution or an assertion fails.
    """
    check_repeated_and_empty_bindings[False]()


def test_gpu_repeated_and_empty_bindings() raises:
    """Checks repeated and empty GPU invocations.

    Raises:
        Error: If execution or an assertion fails.
    """
    comptime if has_accelerator():
        check_repeated_and_empty_bindings[True]()


def update_struct_capture(
    context: KernelContext[
        Filter().include[Int32](),
        capture_spec=Captures[MutCapture[CaptureBias]](),
    ]
):
    """Updates a plain struct capture from a single GPU thread.

    Args:
        context: The matching rows and mutable struct capture.
    """
    comptime if is_gpu():
        if global_idx.x != 0:
            return
    context.captures.get[0]().value += 5


def test_gpu_plain_struct_capture() raises:
    """Copies a struct without TrivialRegisterPassable conformance both ways.

    Raises:
        Error: If execution or an assertion fails.
    """
    comptime if not has_accelerator():
        return
    var world = World[Int32]()
    _ = world.storage.add_entity(Int32(0))
    var value = CaptureBias(7)
    var context = SystemContext(world)
    context.run[update_struct_capture, on_gpu=True](mut_capture(value))
    assert_equal(value.value, 12)


def main() raises:
    """Runs capture regression tests.

    Raises:
        Error: If a test fails.
    """
    TestSuite.discover_tests[__functions_in_module()]().run()
