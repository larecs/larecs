"""Manual host job-dispatch feasibility probe; this is not an execution engine.

Run with `pixi run mojo run -I src docs/design/research/host-thread-dispatch-probe.mojo`.
Uses POSIX pthread_self for diagnostics; validated on Linux only.
"""

from max.algorithm import parallelize
from std.ffi import external_call
from std.testing import assert_equal
from larecs import World, Filter, Resources, Captures, KernelContext
from larecs.system import (
    _host_kernel_context,
    ResourceAccessor,
    _bind_host_resources,
)
from larecs.capture import CaptureAccessor, _bind_captures
from larecs.sync import AtomicValue
from larecs.lock import LockGuard

comptime access = Filter().include[Int32]()


def update_rows(rows: KernelContext[access]):
    """Increments each row in one prepared context.

    Args:
        rows: A disjoint physical store range.
    """
    for row in rows:
        row.set(row.get[Int32]() + 1)


def run_probe[workers: Int, chunk_rows: Int = 0](rows: Int = 256) raises:
    """Checks atomic job claiming and unchanged host kernel iteration.

    Parameters:
        workers: Number of worker tasks requested per invocation.
        chunk_rows: Maximum rows per job; zero retains whole-store jobs.

    Args:
        rows: Number of rows in each of four stores.

    Raises:
        Error: If setup or exact per-row validation fails.
    """
    var world = World[Int32, Float32, UInt8]()
    for i in range(rows):
        _ = world.storage.add_entity(Int32(i))
        _ = world.storage.add_entity(Int32(i), Float32(0))
        _ = world.storage.add_entity(Int32(i), UInt8(0))
        _ = world.storage.add_entity(Int32(i), Float32(0), UInt8(0))
    var structural_lock = LockGuard(Pointer(to=world.storage._locks))
    var binding = _bind_host_resources[Resources[]()](world.resources)
    var resources = ResourceAccessor[Resources[]()](binding.pointers.copy())
    var captures = _bind_captures[Captures[]()]()
    var contexts = List[KernelContext[access]]()
    for ref store in world.storage._archetypes:
        if len(store) > 0:
            var size = len(store)
            comptime if chunk_rows > 0:
                size = chunk_rows
            var first = 0
            while first < len(store):
                var count = min(size, len(store) - first)
                contexts.append(
                    _host_kernel_context[access, Resources[](), Captures[]()](
                        store, first, count, resources, captures
                    )
                )
                assert_equal(Int(contexts[len(contexts) - 1].length), count)
                assert_equal(Int(contexts[len(contexts) - 1].thread_count), 1)
                first += count
    var jobs = contexts.unsafe_ptr()
    var count = len(contexts)
    comptime if chunk_rows > 0:
        assert_equal(count, 4 * ((rows + chunk_rows - 1) // chunk_rows))
    else:
        assert_equal(count, 4)
    var next_owner = AtomicValue[UInt32](0)
    var next_job = next_owner.write_view()
    var lane_storage = List[UInt64]()
    for _ in range(workers):
        lane_storage.append(0)
    var lane_ids = lane_storage.unsafe_ptr()

    def worker(lane: Int) {imm jobs, imm count, imm next_job, imm lane_ids}:
        """Claims store jobs until the invocation is drained.

        Args:
            lane: Fixed worker-task index.
        """
        lane_ids[unsafe_offset=lane] = external_call["pthread_self", UInt64]()
        while True:
            var index = Int(next_job.fetch_add(1))
            if index >= count:
                break
            update_rows(jobs[unsafe_offset=index])

    for _ in range(100):
        next_job.store(0)
        parallelize(worker, workers, workers)
    for ref store in world.storage._archetypes:
        if len(store) > 0:
            var ptr = store._storage.get_component_ptr[Int32]()
            for i in range(len(store)):
                assert_equal(ptr[unsafe_offset=i], Int32(i + 100))
    print(
        "PASS:",
        workers,
        "worker tasks;",
        count,
        "jobs;",
        rows,
        "rows/store; 100 calls",
    )
    print(
        "Last invocation pthread IDs (diagnostic, not a concurrency assertion):"
    )
    for i in range(workers):
        print(lane_ids[unsafe_offset=i])
    binding.release()


def main() raises:
    """Checks serial and parallel dispatch with the same entity kernel.

    Raises:
        Error: If any probe fails.
    """
    run_probe[1]()
    run_probe[2]()
    run_probe[4]()
    run_probe[1, 63](259)
    run_probe[2, 63](259)
    run_probe[4, 63](259)
    run_probe[4, 63](1)
