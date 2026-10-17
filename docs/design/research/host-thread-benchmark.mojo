"""Manual complete-call timings for the host thread dispatch investigation.

Build once without debug/tracing, then run the resulting binary repeatedly.
This does not implement or register a production execution engine.
"""

from max.algorithm import parallelize
from std.benchmark import keep
from std.time import perf_counter_ns
from std.testing import assert_equal
from larecs import (
    World,
    Filter,
    Resources,
    Captures,
    KernelContext,
    SystemContext,
)
from larecs.system import (
    _host_kernel_context,
    ResourceAccessor,
    _bind_host_resources,
)
from larecs.capture import _bind_captures
from larecs.sync import AtomicValue
from larecs.lock import LockGuard

comptime access = Filter().include[UInt32]()
comptime BenchWorld = World[UInt32, Float32, UInt8]


@always_inline
def transform[rounds: Int](value: UInt32) -> UInt32:
    """Computes deterministic row work using wrapping unsigned arithmetic.

    Parameters:
        rounds: Zero for increment; otherwise dependent nonlinear rounds.

    Args:
        value: Previous row value.

    Returns:
        Updated row value.
    """
    var result = value
    comptime if rounds == 0:
        result += 1
    else:
        for _ in range(rounds):
            result = (result ^ (result >> 13)) * 1664525 + 1013904223
    return result


@no_inline
def update[rounds: Int](rows: KernelContext[access]):
    """Updates a physical range with the same code on both dispatch paths.

    Parameters:
        rounds: Per-row arithmetic intensity.

    Args:
        rows: Prepared nonoverlapping writable component range.
    """
    for row in rows:
        row.set(transform[rounds](row.get[UInt32]()))


def populate(mut world: BenchWorld, rows: Int, stores: Int) raises:
    """Creates equally sized stores with identical initial values.

    Args:
        world: Empty world to populate.
        rows: Rows per store.
        stores: One or four physical archetype stores.

    Raises:
        Error: If entity creation fails.
    """
    for _ in world.storage.add_entities(UInt32(1), count=rows):
        pass
    if stores == 4:
        for _ in world.storage.add_entities(UInt32(1), Float32(0), count=rows):
            pass
        for _ in world.storage.add_entities(UInt32(1), UInt8(0), count=rows):
            pass
        for _ in world.storage.add_entities(
            UInt32(1), Float32(0), UInt8(0), count=rows
        ):
            pass


@no_inline
def invoke[
    workers: Int, rounds: Int, threaded: Bool, chunked: Bool = False
](mut world: BenchWorld) raises:
    """Runs one complete ordinary sequential call or experimental threaded call.

    Parameters:
        workers: Number of worker tasks for threaded dispatch.
        rounds: Per-row arithmetic intensity.
        threaded: Select the experimental path.
        chunked: Split stores into contiguous jobs targeting four jobs per worker.

    Args:
        world: World updated by the invocation.

    Raises:
        Error: If context or binding preparation fails.
    """
    comptime if not threaded:
        var context = SystemContext(world)
        context.run[update[rounds]]()
    else:
        var structural_lock = LockGuard(Pointer(to=world.storage._locks))
        var binding = _bind_host_resources[Resources[]()](world.resources)
        var resources = ResourceAccessor[Resources[]()](binding.pointers.copy())
        var captures = _bind_captures[Captures[]()]()
        var contexts = List[KernelContext[access]]()
        var chunk_rows = 0
        comptime if chunked:
            var total_rows = 0
            for ref store in world.storage._archetypes:
                total_rows += len(store)
            # Target four jobs per worker across the world, not per store.
            chunk_rows = max(1, (total_rows + workers * 4 - 1) // (workers * 4))
        for ref store in world.storage._archetypes:
            if len(store) > 0:
                var size = len(store)
                comptime if chunked:
                    size = chunk_rows
                var first = 0
                while first < len(store):
                    var count = min(size, len(store) - first)
                    contexts.append(
                        _host_kernel_context[
                            access, Resources[](), Captures[]()
                        ](store, first, count, resources, captures)
                    )
                    first += count
        var jobs = contexts.unsafe_ptr()
        var count = len(contexts)
        var next_owner = AtomicValue[UInt32](0)
        var next_job = next_owner.write_view()

        def worker(lane: Int) {imm jobs, imm count, imm next_job}:
            """Claims individual jobs until the table is exhausted.

            Args:
                lane: Worker task index, unused for job assignment.
            """
            while True:
                var index = Int(next_job.fetch_add(1))
                if index >= count:
                    break
                update[rounds](jobs[unsafe_offset=index])

        parallelize(worker, workers, workers)
        binding.release()


def batch[
    workers: Int, rounds: Int, threaded: Bool, chunked: Bool = False
](mut world: BenchWorld, frames: Int) raises -> Int:
    """Times a bounded batch of complete invocations.

    Parameters:
        workers: Worker task count.
        rounds: Per-row arithmetic intensity.
        threaded: Dispatch path.
        chunked: Split stores into contiguous jobs.

    Args:
        world: Mutable benchmark world.
        frames: Number of complete calls to time.

    Raises:
        Error: If an invocation fails.

    Returns:
        Elapsed nanoseconds for the entire batch.
    """
    var start = perf_counter_ns()
    for _ in range(frames):
        invoke[workers, rounds, threaded, chunked](world)
        keep(len(world))
    return Int(perf_counter_ns() - start)


def validate[rounds: Int](mut world: BenchWorld, frames: Int, rows: Int) raises:
    """Checks every resulting row outside the timed region.

    Parameters:
        rounds: Arithmetic intensity used for all calls.

    Args:
        world: Completed benchmark world.
        frames: Total calls including warmup and calibration.
        rows: Expected total row count.

    Raises:
        Error: If any value or membership is wrong.
    """
    var expected = UInt32(1)
    for _ in range(frames):
        expected = transform[rounds](expected)
    var visited = 0
    for row in world.storage.query[Filter().read[UInt32]()]():
        assert_equal(row.get[UInt32](), expected)
        visited += 1
    assert_equal(visited, rows)


def measure[
    workers: Int, rounds: Int, chunked: Bool
](rows: Int, stores: Int) raises:
    """Warms both paths and emits five alternating paired timings.

    Parameters:
        workers: Fixed worker task count.
        rounds: Per-row arithmetic intensity.
        chunked: Split stores into contiguous jobs.

    Args:
        rows: Rows per physical store.
        stores: Number of stores, one or four.

    Raises:
        Error: If setup, dispatch, or per-row validation fails.
    """
    var sequential = BenchWorld()
    populate(sequential, rows, stores)
    var threaded = BenchWorld()
    populate(threaded, rows, stores)
    _ = batch[workers, rounds, False, chunked](sequential, 2)
    _ = batch[workers, rounds, True, chunked](threaded, 2)
    var serial_calls = 2
    var threaded_calls = 2
    var frames = 1
    while True:
        var elapsed = batch[workers, rounds, False, chunked](sequential, frames)
        serial_calls += frames
        if elapsed >= 10_000_000 or frames >= 4096:
            break
        frames *= 2
    for pair in range(5):
        var serial_ns: Int
        var threaded_ns: Int
        if pair % 2 == 0:
            serial_ns = batch[workers, rounds, False, chunked](
                sequential, frames
            )
            threaded_ns = batch[workers, rounds, True, chunked](
                threaded, frames
            )
        else:
            threaded_ns = batch[workers, rounds, True, chunked](
                threaded, frames
            )
            serial_ns = batch[workers, rounds, False, chunked](
                sequential, frames
            )
        serial_calls += frames
        threaded_calls += frames
        print(
            "PAIR",
            Int(chunked),
            rows,
            stores,
            rounds,
            workers,
            pair,
            frames,
            Float64(serial_ns) / Float64(frames),
            Float64(threaded_ns) / Float64(frames),
        )
    validate[rounds](sequential, serial_calls, rows * stores)
    validate[rounds](threaded, threaded_calls, rows * stores)


def scenarios[workers: Int, chunked: Bool]() raises:
    """Runs the original small workload, larger worlds, and a one-job control.

    Parameters:
        workers: Fixed worker task count.
        chunked: Split stores into contiguous jobs.

    Raises:
        Error: If any benchmark case fails validation.
    """
    for rows in [256, 16384, 262144]:
        measure[workers, 0, chunked](rows, 4)
        measure[workers, 32, chunked](rows, 4)
    measure[workers, 0, chunked](262144, 1)
    measure[workers, 32, chunked](262144, 1)
    measure[workers, 32, chunked](1048576, 1)


def main() raises:
    """Runs the bounded manual matrix with one, two, and four worker tasks.

    Raises:
        Error: If any case fails validation.
    """
    scenarios[1, False]()
    scenarios[1, True]()
    scenarios[2, False]()
    scenarios[2, True]()
    scenarios[4, False]()
    scenarios[4, True]()
