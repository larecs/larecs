from std.benchmark import Bench, Bencher, BenchId
from custom_benchmark import DefaultBench
from larecs.test_utils import *


def benchmark_add_remove_5_comp_batch_1_000_000(
    mut bencher: Bencher,
):
    var world = SmallWorld()

    @always_inline
    def bench_fn() {mut world}:
        try:
            # create 1_000_000 entities that initially do not have FlexibleComponent[1]
            _ = world.storage.add_entities(Position(1.0, 2.0), count=1_000_000)

            _ = world.storage.add(
                world.storage.query[Position]().without[
                    FlexibleComponent[1],
                    FlexibleComponent[2],
                    FlexibleComponent[3],
                    FlexibleComponent[4],
                    FlexibleComponent[5],
                ](),
                FlexibleComponent[1](1.0, 42.0),
                FlexibleComponent[2](2.0, 42.0),
                FlexibleComponent[3](3.0, 42.0),
                FlexibleComponent[4](4.0, 42.0),
                FlexibleComponent[5](5.0, 42.0),
            )
            _ = world.storage.remove[
                FlexibleComponent[1],
                FlexibleComponent[2],
                FlexibleComponent[3],
                FlexibleComponent[4],
                FlexibleComponent[5],
            ](
                world.storage.query[
                    Position,
                    FlexibleComponent[1],
                    FlexibleComponent[2],
                    FlexibleComponent[3],
                    FlexibleComponent[4],
                    FlexibleComponent[5],
                ]()
            )
        except e:
            print(e)

    bencher.iter(bench_fn)


def benchmark_add_remove_5_comp_1_000_batch_1_000(
    mut bencher: Bencher,
):
    var world = SmallWorld()

    @always_inline
    def bench_fn() {mut world}:
        try:
            # create 1_000 entities that initially do not have FlexibleComponent[1...5]
            _ = world.storage.add_entities(Position(1.0, 2.0), count=1_000)
            # then 1_000 x add components and remove them afterwards
            for _ in range(1000):
                _ = world.storage.add(
                    world.storage.query[Position]().without[
                        FlexibleComponent[1],
                        FlexibleComponent[2],
                        FlexibleComponent[3],
                        FlexibleComponent[4],
                        FlexibleComponent[5],
                    ](),
                    FlexibleComponent[1](1.0, 42.0),
                    FlexibleComponent[2](1.0, 42.0),
                    FlexibleComponent[3](1.0, 42.0),
                    FlexibleComponent[4](1.0, 42.0),
                    FlexibleComponent[5](1.0, 42.0),
                )
                _ = world.storage.remove[
                    FlexibleComponent[1],
                    FlexibleComponent[2],
                    FlexibleComponent[3],
                    FlexibleComponent[4],
                    FlexibleComponent[5],
                ](
                    world.storage.query[
                        Position,
                        FlexibleComponent[1],
                        FlexibleComponent[2],
                        FlexibleComponent[3],
                        FlexibleComponent[4],
                        FlexibleComponent[5],
                    ]()
                )
        except e:
            print(e)

    bencher.iter(bench_fn)


def run_all_world_component_multi_batch_benchmarks() raises:
    var bench = DefaultBench()
    run_all_world_component_multi_batch_benchmarks(bench)
    bench.dump_report()


def run_all_world_component_multi_batch_benchmarks(mut bench: Bench) raises:
    bench.bench_function(
        benchmark_add_remove_5_comp_batch_1_000_000,
        BenchId("10^0 * add & remove 5 components 10^6 batch"),
    )
    bench.bench_function(
        benchmark_add_remove_5_comp_1_000_batch_1_000,
        BenchId("10^3 * add & remove 5 components 10^3 batch"),
    )
