from std.benchmark import Bench, BenchConfig, Bencher, keep, BenchId

from custom_benchmark import DefaultBench
from bitmask_benchmark import get_random_bitmask
from larecs.archetype import Archetype as _Archetype
from larecs.bitmask import BitMask
from larecs.test_utils import FlexibleComponent, LargerComponent

comptime Archetype = _Archetype[
    FlexibleComponent[0],
    LargerComponent,
    FlexibleComponent[1],
    FlexibleComponent[2],
    FlexibleComponent[3],
    FlexibleComponent[4],
    FlexibleComponent[5],
    FlexibleComponent[6],
    FlexibleComponent[7],
    FlexibleComponent[9],
    FlexibleComponent[10],
]


def benchmark_archetype_bitmask_contains_1_000_000(
    mut bencher: Bencher,
):
    mask = get_random_bitmask()

    archetype = Archetype(0, mask, 10)

    @always_inline
    def bench_fn() {imm}:
        for _ in range(1_000_000):
            keep(archetype.get_mask().contains(mask))

    bencher.iter(bench_fn)


def run_all_archetype_benchmarks() raises:
    bench = DefaultBench()
    run_all_archetype_benchmarks(bench)
    bench.dump_report()


def run_all_archetype_benchmarks(mut bench: Bench) raises:
    bench.bench_function(
        benchmark_archetype_bitmask_contains_1_000_000,
        BenchId("10^6 * archetype bitmask contains"),
    )
