"""Measure reset and reserved-memory allocation costs separately.

Run with `pixi run mojo run --lld-path /usr/bin/ld -I src
benchmark/pool_reset_benchmark.mojo`. Each size is warmed up before timing;
allocation samples reuse the pool's reserved storage.
"""

from std.benchmark import keep
from std.time import perf_counter_ns

from larecs.pool import EntityPool


def benchmark_reset(size: Int, repeats: Int):
    """Print average reset latency and allocation latency per entity.

    Args:
        size: Number of entities allocated before each reset.
        repeats: Number of measured reset/allocation cycles.
    """
    var pool = EntityPool()
    for _ in range(size):
        keep(pool.get())
    var reset_ns = Int(0)
    var allocation_ns = Int(0)
    for _ in range(repeats):
        var start = perf_counter_ns()
        pool.reset()
        reset_ns += perf_counter_ns() - start
        start = perf_counter_ns()
        for _ in range(size):
            keep(pool.get())
        allocation_ns += perf_counter_ns() - start
    print(
        size,
        Float64(reset_ns) / Float64(repeats),
        Float64(allocation_ns) / Float64(repeats * size),
        sep=",",
    )


def main():
    """Run focused reset/allocation measurements at three pool sizes."""
    print("entities,reset_ns,allocation_ns_per_entity")
    benchmark_reset(1024, 64)
    benchmark_reset(65536, 64)
    benchmark_reset(1048576, 32)
