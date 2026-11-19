"""Paired complete-call timings for experimental threaded host execution.

Build once without debug/tracing and run repeatedly; outside the PR timing gate.
"""

from std.benchmark import keep
from std.time import perf_counter_ns
from std.testing import assert_equal
from larecs import (
    World,
    Filter,
    KernelContext,
    SystemContext,
    ThreadedExecutionConfig,
)

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


def populate(
    mut world: BenchWorld, rows: Int, stores: Int, skewed: Bool = False
) raises:
    """Creates stores with identical initial row values.

    Args:
        world: Empty world to populate.
        rows: Rows per store.
        stores: One or four physical archetype stores.
        skewed: Give the first store seven times the rows of each other store.

    Raises:
        Error: If entity creation fails.
    """
    for _ in world.storage.add_entities(
        UInt32(1), count=rows * 7 if skewed else rows
    ):
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
def invoke[rounds: Int, threaded: Bool](mut world: BenchWorld) raises:
    """Runs one complete public invocation with identical row work.

    Parameters:
        rounds: Arithmetic intensity.
        threaded: Whether to select the experimental engine.

    Args:
        world: Prepared benchmark world.

    Raises:
        Error: If invocation preparation fails.
    """
    var context = SystemContext(world)
    context.run[update[rounds], threaded=threaded]()


def batch[
    rounds: Int, threaded: Bool
](mut world: BenchWorld, frames: Int) raises -> Int:
    """Times a bounded batch of complete invocations.

    Parameters:
        rounds: Per-row arithmetic intensity.
        threaded: Dispatch path.

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
        invoke[rounds, threaded](world)
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
    workers: Int, rounds: Int
](rows: Int, stores: Int, skewed: Bool = False) raises:
    """Warms both paths and emits five alternating paired timings.

    Parameters:
        workers: Fixed worker task count.
        rounds: Per-row arithmetic intensity.

    Args:
        rows: Rows per physical store.
        stores: Number of stores, one or four.
        skewed: Use a seven-to-one row distribution across four stores.

    Raises:
        Error: If setup, dispatch, or per-row validation fails.
    """
    var sequential = BenchWorld()
    populate(sequential, rows, stores, skewed)
    var threaded = BenchWorld(
        execution_config=ThreadedExecutionConfig(
            workers=workers, min_parallel_rows=0
        )
    )
    populate(threaded, rows, stores, skewed)
    _ = batch[rounds, False](sequential, 2)
    _ = batch[rounds, True](threaded, 2)
    var serial_calls = 2
    var threaded_calls = 2
    var frames = 1
    while True:
        var elapsed = batch[rounds, False](sequential, frames)
        serial_calls += frames
        if elapsed >= 10_000_000 or frames >= 4096:
            break
        frames *= 2
    for pair in range(5):
        var serial_ns: Int
        var threaded_ns: Int
        if pair % 2 == 0:
            serial_ns = batch[rounds, False](sequential, frames)
            threaded_ns = batch[rounds, True](threaded, frames)
        else:
            threaded_ns = batch[rounds, True](threaded, frames)
            serial_ns = batch[rounds, False](sequential, frames)
        serial_calls += frames
        threaded_calls += frames
        print(
            "PAIR",
            Int(skewed),
            rows,
            stores,
            rounds,
            workers,
            pair,
            frames,
            Float64(serial_ns) / Float64(frames),
            Float64(threaded_ns) / Float64(frames),
        )
    validate[rounds](
        sequential, serial_calls, rows * (10 if skewed else stores)
    )
    validate[rounds](
        threaded, threaded_calls, rows * (10 if skewed else stores)
    )


def scenarios[workers: Int]() raises:
    """Runs the original small workload, larger worlds, and a one-job control.

    Parameters:
        workers: Fixed worker task count.

    Raises:
        Error: If any benchmark case fails validation.
    """
    for rows in [256, 16384, 262144]:
        measure[workers, 0](rows, 4)
        measure[workers, 32](rows, 4)
    measure[workers, 0](262144, 1)
    measure[workers, 32](262144, 1)
    measure[workers, 32](1048576, 1)
    measure[workers, 32](16384, 4, True)


def main() raises:
    """Runs the bounded manual matrix with one, two, and four worker tasks.

    Raises:
        Error: If any case fails validation.
    """
    scenarios[1]()
    scenarios[2]()
    scenarios[4]()
