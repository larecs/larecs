"""Complete edited-source adapter invocations, including optional buffer growth.

Construction and final checks are excluded. Source edits, host growth, validation,
leases, GPU allocation/upload, component output transfers and synchronization
are included. Only the first sample is read; all 4,096 initial samples are uploaded.

`repeated` times 13 unchanged device runs per update, as in Tree-D's per-direction
leaf-layer kernel, with and without device copy reuse (decision 0021), and
reports uploaded bytes per update.
"""
from std.time import perf_counter_ns
from std.testing import assert_equal
from std.sys import has_accelerator
from larecs import (
    BufferResource,
    World,
    SystemContext,
    KernelContext,
    Resources,
    Filter,
)
from resource_execution_benchmark import check

comptime Samples = BufferResource[DType.int32]
comptime required = Resources().read[Samples]()


def adapted(rows: KernelContext[Filter().include[Int32](), required]):
    """Reads the first sample while complete source storage is uploaded.

    Args:
        rows: Matching rows and portable sample view.
    """
    var delta = rows.resources.get[Samples]()[0]
    for entity in rows:
        entity.get[Int32]() += delta


def adapter[device: Bool, growing: Bool]() raises:
    """Times edited-source invocations, optionally growing sample storage.

    Parameters:
        device: Execution backend.
        growing: Whether to append a sample inside every timed invocation.

    Raises:
        Error: If execution or checks fail.
    """
    comptime iterations = 100 if device else 10_000
    var samples = List[Int32](capacity=4096)
    for _ in range(4096):
        samples.append(1)
    var world = World[Int32]()
    world.resources.add(Samples(samples^))
    for _ in world.storage.add_entities(Int32(0), count=512):
        pass
    var context = SystemContext(world)
    context.run[adapted, on_device=device]()
    var start = perf_counter_ns()
    for i in range(iterations):
        ref source = world.resources.get[Samples]()
        source.samples[0] = Int32(1 + i % 2)
        comptime if growing:
            source.samples.append(1)
        context.run[adapted, on_device=device]()
    var elapsed = Float64(perf_counter_ns() - start) / Float64(iterations)
    check(world, Int32(1 + iterations + iterations // 2))
    assert_equal(
        len(world.resources.get[Samples]().samples),
        4096 + (iterations if growing else 0),
    )
    print("adapter", device, growing, elapsed)


def written(rows: KernelContext[Filter().write[Int32](), required]):
    """Writes the first sample to every row without reading components.

    Args:
        rows: Write-only rows and portable sample view.
    """
    var value = rows.resources.get[Samples]()[0]
    for entity in rows:
        entity.set(value)


def repeated[reuse: Bool]() raises:
    """Times updates of 13 unchanged device runs over a 16 MiB resource.

    Parameters:
        reuse: Whether the world reuses unchanged device copies.

    Raises:
        Error: If execution or checks fail.
    """
    comptime updates = 10
    comptime runs = 13
    var world = World[Int32]()
    world.resources.add(Samples(List[Int32](length=1 << 22, fill=3)))
    for _ in world.storage.add_entities(Int32(0), count=512):
        pass
    world.reuse_device_copies(reuse)
    var context = SystemContext(world)
    context.run[written, on_device=True]()
    var bytes = 0
    var start = perf_counter_ns()
    for i in range(updates):
        world.resources.get[Samples]().samples[0] = Int32(i)
        for _ in range(runs):
            context.run[written, on_device=True]()
            bytes += world._last_device_upload.bytes
    var elapsed = Float64(perf_counter_ns() - start) / Float64(updates)
    check(world, Int32(updates - 1))
    print("repeated", reuse, elapsed, bytes // updates)


def main() raises:
    """Reports bounded mean nanoseconds per complete invocation.

    Raises:
        Error: If execution or correctness checks fail.
    """
    adapter[False, False]()
    adapter[False, True]()
    comptime if has_accelerator():
        adapter[True, False]()
        adapter[True, True]()
        repeated[False]()
        repeated[True]()
