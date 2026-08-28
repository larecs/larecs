from std.benchmark import Bench, BenchConfig, Bencher, keep, BenchId
import std.random

from custom_benchmark import DefaultBench
from larecs.bitmask import BitMask
from larecs.test_utils import get_random_bitmask


def benchmark_bitmask_get_1_000_000(mut bencher: Bencher):
    var mask = get_random_bitmask()
    var val = Int(std.random.random_si64(0, Int64(BitMask.total_bits - 1)))

    @always_inline
    def bench_fn() {mut}:
        for _ in range(1_000_000):
            keep(mask.get(val))

    bencher.iter(bench_fn)


def benchmark_bitmask_set_1_000_000(mut bencher: Bencher):
    var mask = get_random_bitmask()
    var val = Int(std.random.random_si64(0, Int64(BitMask.total_bits - 1)))

    @always_inline
    def bench_fn() {mut}:
        var bit_val = True
        for _ in range(1_000_000):
            mask.set(val, bit_val)
            keep(mask._bytes)
            bit_val = not bit_val

    bencher.iter(bench_fn)


def benchmark_bitmask_flip_1_000_000(mut bencher: Bencher):
    var mask = get_random_bitmask()
    var val = Int(std.random.random_si64(0, Int64(BitMask.total_bits - 1)))

    @always_inline
    def bench_fn() {mut}:
        for _ in range(1_000_000):
            mask.flip(val)
            keep(mask._bytes)

    bencher.iter(bench_fn)


def benchmark_bitmask_contains_1_000_000(mut bencher: Bencher):
    var mask = get_random_bitmask()
    var val = BitMask(
        Int(std.random.random_si64(0, Int64(BitMask.total_bits - 1)))
    )

    @always_inline
    def bench_fn() {mut}:
        for _ in range(1_000_000):
            keep(mask.contains(val))

    bencher.iter(bench_fn)


def benchmark_bitmask_contains_any_1_000_000(mut bencher: Bencher):
    var mask = get_random_bitmask()
    var val = BitMask(
        Int(std.random.random_si64(0, Int64(BitMask.total_bits - 1)))
    )

    @always_inline
    def bench_fn() {mut}:
        for _ in range(1_000_000):
            keep(mask.contains_any(val))

    bencher.iter(bench_fn)


def benchmark_bitmask_eq_1_000_000(mut bencher: Bencher):
    var mask1 = get_random_bitmask()
    var mask2 = mask1
    var mask3 = get_random_bitmask()

    @always_inline
    def bench_fn() {mut}:
        for _ in range(500_000):
            keep(mask1 == mask2)
            keep(mask1 == mask3)

    bencher.iter(bench_fn)


def benchmark_bitmask_get_indices_1_000_000(mut bencher: Bencher):
    mask = get_random_bitmask()

    @always_inline
    def bench_fn() {mut}:
        for _ in range(1_000_000):
            ind = mask.get_indices()
            # keep(mask.get_indices()) #.data[10])
            for i in ind:
                keep(i)

    bencher.iter(bench_fn)


def benchmark_bitmask_get_each_1_000_000(mut bencher: Bencher):
    var mask = get_random_bitmask()

    @always_inline
    def bench_fn() {mut}:
        for _ in range(1_000_000):
            # ind = mask.get_indices()
            # keep(mask.get_indices()) #.data[10])
            comptime for i in range(256):
                if mask.get(i):
                    keep(i)

    bencher.iter(bench_fn)


#     var v: Bool
#     for i = 0; i < b.N; i++:
#         v = mask.matches(bits)

#     b.StopTimer()
#     v = !v
#     _ = v


# def BenchmarkMaskPointer(b *testing.B):
#     b.StopTimer()
#     mask = maskPointer(BitMask(0, 1, 2))
#     bits = BitMask(0, 1, 2)
#     b.StartTimer()
#     var v: Bool
#     for i = 0; i < b.N; i++:
#         v = mask.matches(bits)

#     b.StopTimer()
#     v = !v
#     _ = v


# def BenchmarkMask(b *testing.B):
#     b.StopTimer()
#     mask = BitMask(0, 1, 2)
#     bits = BitMask(0, 1, 2)
#     b.StartTimer()
#     var v: Bool
#     for i = 0; i < b.N; i++:
#         v = mask.matches(bits)


#     b.StopTimer()
#     v = !v
#     _ = v
def run_all_bitmask_benchmarks() raises:
    var bench = DefaultBench()
    run_all_bitmask_benchmarks(bench)
    bench.dump_report()


def run_all_bitmask_benchmarks(mut bench: Bench) raises:
    bench.bench_function(
        benchmark_bitmask_get_1_000_000, BenchId("10^6 * bitmask_get")
    )
    bench.bench_function(
        benchmark_bitmask_set_1_000_000, BenchId("10^6 * bitmask_set")
    )
    bench.bench_function(
        benchmark_bitmask_flip_1_000_000, BenchId("10^6 * bitmask_flip")
    )
    bench.bench_function(
        benchmark_bitmask_contains_1_000_000, BenchId("10^6 * bitmask_contains")
    )
    bench.bench_function(
        benchmark_bitmask_contains_any_1_000_000,
        BenchId("10^6 * bitmask_contains_any"),
    )
    bench.bench_function(
        benchmark_bitmask_eq_1_000_000, BenchId("10^6 * bitmask_eq")
    )
    # bench.bench_function(benchmark_bitmask_get_indices_1_000_000,
    #     BenchId("10^6 * get_indices")
    # )
    bench.bench_function(
        benchmark_bitmask_get_each_1_000_000, BenchId("10^6 * get_each")
    )
