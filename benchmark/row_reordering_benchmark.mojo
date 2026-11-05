"""Measures the row-permutation foundation, excluding spatial classification."""

from std.benchmark import Bench, BenchId, Bencher, keep
from std.os import abort
from custom_benchmark import DefaultBench
from larecs.host_storage import HostStorage


comptime ROW_COUNT = 100_000
"""Rows moved by each benchmark pass."""


def _bench_reorder[identity: Bool](mut bencher: Bencher):
    """Measures validation, planning, all-column movement, and location repair.

    Parameters:
        identity: Whether to use an already ordered mapping instead of reversal.

    Args:
        bencher: Benchmark driver.
    """
    try:
        var storage = HostStorage[Int, SIMD[DType.float32, 16]]()
        for _ in storage.add_entities(
            0, SIMD[DType.float32, 16](1), count=ROW_COUNT
        ):
            pass
        var order = List[Int](capacity=ROW_COUNT)
        for row in range(ROW_COUNT):
            comptime if identity:
                order.append(row)
            else:
                order.append(ROW_COUNT - row - 1)
        var index = storage._entity_locations[1].archetype_index

        def run_once() {mut storage, imm order, imm index}:
            """Applies the same mapping; reversal moves rows on every pass."""
            try:
                storage._reorder_archetype_rows(index, order)
                keep(storage._archetypes[index].get_entity(0))
            except err:
                print(err)
                abort("Row reordering benchmark failed")

        bencher.iter(run_once)
    except err:
        print(err)
        abort("Row reordering benchmark setup failed")


def run_all_row_reordering_benchmarks(mut bench: Bench) raises:
    """Registers permutation-only costs for wide component rows.

    Args:
        bench: Benchmark registry.

    Raises:
        Error: If benchmark registration fails.
    """
    bench.bench_function(
        _bench_reorder[False],
        BenchId("row reordering, 100k reverse, 72 bytes per row"),
        fixed_iterations=20,
    )
    bench.bench_function(
        _bench_reorder[True],
        BenchId("row reordering, 100k identity, 72 bytes per row"),
        fixed_iterations=20,
    )


def main() raises:
    """Runs the permutation benchmarks independently.

    Raises:
        Error: If benchmark registration or reporting fails.
    """
    var bench = DefaultBench()
    run_all_row_reordering_benchmarks(bench)
    bench.dump_report()
