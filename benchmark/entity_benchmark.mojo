from std.benchmark import Bencher, Bench, keep, BenchId
from custom_benchmark import DefaultBench
from larecs.entity import Entity


def benchmark_entity_is_zero(mut bencher: Bencher):
    e = Entity()

    def bench_fn(calls: Int) {imm} -> Int:
        for _ in range(calls):
            keep(e.is_zero())
        return calls

    bencher.iter_custom(bench_fn)


def run_all_entity_benchmarks() raises:
    bench = DefaultBench()
    run_all_entity_benchmarks(bench)
    bench.dump_report()


def run_all_entity_benchmarks(mut bench: Bench) raises:
    bench.bench_function(
        benchmark_entity_is_zero, BenchId("10^6 * entity is zero")
    )


def main() raises:
    run_all_entity_benchmarks()
