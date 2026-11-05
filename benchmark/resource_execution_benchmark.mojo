"""Fixed complete resource invocations with matched base/current workloads.

Bases predating ExecutionBackend need the call-spelling adaptation documented
in docs/src/guide/benchmarks.md; keep all workload and timing code identical.
Construction and final checks are excluded; transfers and synchronization are
included.
"""
from std.time import perf_counter_ns
from std.testing import assert_equal
from std.sys import has_accelerator
from larecs import (
    ExecutionBackend,
    World,
    SystemContext,
    KernelContext,
    Filter,
    Resources,
    ResourceType,
)


@fieldwise_init
struct Scale(ResourceType):
    """Unchanged plain-resource representation."""

    var value: Int32


def control(rows: KernelContext[Filter().include[Int32]()]):
    """Increments rows without resources.

    Args:
        rows: Matching component rows.
    """
    for entity in rows:
        entity.get[Int32]() += 1


def plain(rows: KernelContext[Filter().include[Int32](), Resources[Scale]()]):
    """Reads the legacy plain resource on either backend.

    Args:
        rows: Matching rows and scale resource.
    """
    var delta = rows.resources.get[Scale]().value
    for entity in rows:
        entity.get[Int32]() += delta


def check(mut world: World[Int32], expected: Int32) raises:
    """Consumes and checks outputs outside timing.

    Args:
        world: Completed benchmark world.
        expected: Required row value.

    Raises:
        Error: If outputs differ or rows were lost.
    """
    var count = 0
    for entity in world.storage.query[Filter().include[Int32]()]():
        assert_equal(entity.get[Int32](), expected)
        count += 1
    assert_equal(count, 512)


def ordinary[device: Bool, resource: Bool]() raises:
    """Times ordinary-resource or resource-free invocations.

    Parameters:
        device: Whether to use the accelerator.
        resource: Whether to include the plain resource.

    Raises:
        Error: If execution or checks fail.
    """
    comptime iterations = 100 if device else 10_000
    var world = World[Int32]()
    world.resources.add(Scale(1))
    for _ in world.storage.add_entities(Int32(0), count=512):
        pass
    var context = SystemContext(world)
    comptime if resource:
        context.run[
            plain,
            backend=(
                ExecutionBackend.DEVICE if device else ExecutionBackend.HOST
            ),
        ]()
    else:
        context.run[
            control,
            backend=(
                ExecutionBackend.DEVICE if device else ExecutionBackend.HOST
            ),
        ]()
    var start = perf_counter_ns()
    for _ in range(iterations):
        comptime if resource:
            context.run[
                plain,
                backend=(
                    ExecutionBackend.DEVICE if device else ExecutionBackend.HOST
                ),
            ]()
        else:
            context.run[
                control,
                backend=(
                    ExecutionBackend.DEVICE if device else ExecutionBackend.HOST
                ),
            ]()
    var elapsed = Float64(perf_counter_ns() - start) / Float64(iterations)
    check(world, Int32(iterations + 1))
    assert_equal(world.resources.get[Scale]().value, 1)
    print("ordinary", device, resource, elapsed)


def main() raises:
    """Reports mean nanoseconds per bounded invocation after one warmup.

    Raises:
        Error: If any benchmark or check fails.
    """
    ordinary[False, False]()
    ordinary[False, True]()
    comptime if has_accelerator():
        ordinary[True, False]()
        ordinary[True, True]()
