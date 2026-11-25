"""Fixed-row GPU upload sweep; run without debug info on real hardware.

Reports synchronized system times and capacity-observed column growth. Cold
samples discard only device columns after JIT warmup; warm samples reuse them.
"""

from max.gpu.host import DeviceContext
from std.sys import has_accelerator, size_of
from std.time import perf_counter_ns
from std.testing import assert_equal
from larecs import ExecutionBackend, World, SystemContext, KernelContext, Filter
from larecs.device_storage import DeviceComponentStorage


@fieldwise_init
struct Value(TrivialRegisterPassable):
    var x: Float32


@fieldwise_init
struct Tag[index: Int](TrivialRegisterPassable):
    var x: Int32


comptime WorldType = World[
    Value, Tag[0], Tag[1], Tag[2], Tag[3], Tag[4], Tag[5], Tag[6], Tag[7]
]
comptime ROWS = 65_536
comptime REPEATS = 20


def bump(context: KernelContext[Filter().include[Value]()]):
    """Updates each row to make uploads and downloads observable.

    Args:
        context: The flattened GPU rows.
    """
    for entity in context:
        entity.get[Value]().x += 1


def run_once(mut world: WorldType) raises:
    """Runs and synchronizes one GPU system call.

    Args:
        world: The populated world.

    Raises:
        Error: If GPU execution fails.
    """
    var context = SystemContext(world)
    context.run[bump, backend=ExecutionBackend.DEVICE]()


def sweep[count: Int]() raises:
    """Measures fixed total rows split across matching archetypes.

    Parameters:
        count: Number of matching archetypes.

    Raises:
        Error: If GPU execution or verification fails.
    """
    var world = WorldType()
    comptime for i in range(count):
        for _ in world.storage.add_entities(
            Value(0), Tag[i](0), count=ROWS // count
        ):
            pass
    run_once(world)
    var device_context = world._device_storage[]._device_context
    var cold_ns: Int = 0
    for _ in range(REPEATS):
        world._device_storage = {
            WorldType.DeviceComponentStorage(device_context, 0)
        }
        var start = perf_counter_ns()
        run_once(world)
        cold_ns += perf_counter_ns() - start
    var start = perf_counter_ns()
    for _ in range(REPEATS):
        run_once(world)
    var warm_ns = perf_counter_ns() - start

    # Observe capacity at each upload boundary: every capacity change is one
    # allocation, and growth with valid rows copies exactly that prefix.
    var storage = DeviceComponentStorage[Value](DeviceContext(), 0)
    var data = List[Value](unsafe_uninit_length=ROWS // count)
    for i in range(len(data)):
        data[i] = Value(Float32(i))
    storage.reserve_column[Value](ROWS)
    var capacity = len(storage._columns[0].unsafe_value())
    var allocations = Int(storage.has_component[Value]())
    var copied_bytes = 0
    for i in range(count):
        storage.copy_from_host[Value](Span(data), offset=i * len(data))
        var next_capacity = len(storage._columns[0].unsafe_value())
        if next_capacity != capacity:
            allocations += 1
            copied_bytes += i * len(data) * size_of[Value]()
        capacity = next_capacity
    var result = storage.copy_to_host[Value]()
    assert_equal(len(result), ROWS)
    assert_equal(result[ROWS - 1].x, Float32(len(data) - 1))
    print(
        count,
        cold_ns // REPEATS,
        warm_ns // REPEATS,
        allocations,
        copied_bytes,
        capacity,
    )


def growing() raises:
    """Measures 65 successive uploads increasing by one row per call.

    Raises:
        Error: If a device operation or verification fails.
    """
    var storage = DeviceComponentStorage[Value](DeviceContext(), 0)
    var capacity = 0
    var allocations = 0
    var copied_bytes = 0
    var start = perf_counter_ns()
    for rows in range(1, 66):
        var data = List[Value](unsafe_uninit_length=rows)
        for i in range(rows):
            data[i] = Value(Float32(i))
        storage.reserve_column[Value](rows)
        storage.copy_from_host[Value](Span(data))
        var next_capacity = len(storage._columns[0].unsafe_value())
        if next_capacity != capacity:
            allocations += 1
            copied_bytes += (rows - 1) * size_of[Value]()
        capacity = next_capacity
        storage.synchronize()
    var elapsed = perf_counter_ns() - start
    var result = storage.copy_to_host[Value]()
    assert_equal(len(result), 65)
    assert_equal(result[64].x, 64)
    print("growing_1_to_65_ns allocations d2d_bytes capacity_bytes")
    print(elapsed, allocations, copied_bytes, capacity)


def main() raises:
    """Prints nanoseconds per call and allocation/copy/memory observations.

    Raises:
        Error: If a measurement fails.
    """
    comptime if has_accelerator():
        print("archetypes cold_ns warm_ns allocations d2d_bytes capacity_bytes")
        sweep[1]()
        sweep[2]()
        sweep[4]()
        sweep[8]()
        growing()
    else:
        raise Error("Requires real GPU hardware")
