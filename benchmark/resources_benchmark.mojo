from std.benchmark import Bencher, Bench, keep, BenchId
from custom_benchmark import DefaultBench
from larecs import Resources, ResourceType


@fieldwise_init
struct TestResource[size: Int = 1000](ResourceType):
    var _storage: Array[Float64, Self.size]

    def __init__(out self, value: Float64 = 0):
        self._storage = Array[Float64, Self.size](fill=value)


def benchmark_add_remove_resource_1_000(mut bencher: Bencher):
    resources = Resources()

    @always_inline
    def bench_fn() {mut}:
        test_resource = TestResource()
        for _ in range(1_000):
            try:
                resources.add(test_resource.copy())
                resources.remove[TestResource[]]()
            except:
                pass

    bencher.iter(bench_fn)


def benchmark_get_resource_1_000(mut bencher: Bencher):
    resources = Resources()

    try:
        resources.add(TestResource())
    except e:
        print(e)

    @always_inline
    def bench_fn() {mut}:
        for _ in range(1_000):
            try:
                keep(resources.get[TestResource[]]()._storage[0])
            except:
                pass

    bencher.iter(bench_fn)


def run_all_resource_benchmarks() raises:
    bench = DefaultBench()
    run_all_resource_benchmarks(bench)
    bench.dump_report()


def run_all_resource_benchmarks(mut bench: Bench) raises:
    bench.bench_function(
        benchmark_add_remove_resource_1_000,
        BenchId("10^3 * add + remove resource (1000 Float64)"),
    )
    bench.bench_function(
        benchmark_get_resource_1_000,
        BenchId("10^3 * get resource (1000 Float64)"),
    )
