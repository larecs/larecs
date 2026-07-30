from std.benchmark import Bench, Bencher, BenchId
from custom_benchmark import DefaultBench
from larecs.test_utils import *


def prevent_inlining_add_remove_batch() raises:
    world = SmallWorld()
    _ = world.storage.add_entities(Position(1.0, 2.0), count=1)
    _ = world.storage.add(
        world.storage.query[Position]().without[FlexibleComponent[1]](),
        FlexibleComponent[1](1.0, 42.0),
    )
    _ = world.storage.remove[FlexibleComponent[1]](
        world.storage.query[Position, FlexibleComponent[1]]()
    )


def benchmark_add_remove_1_comp_batch_1_000_000(
    mut bencher: Bencher,
):
    world = SmallWorld()
    try:
        # create 1_000_000 entities that initially do not have FlexibleComponent[1]
        _ = world.storage.add_entities(Position(1.0, 2.0), count=1_000_000)
    except e:
        print(e)
        return

    @always_inline
    def bench_fn() {imm, mut world}:
        try:
            _ = world.storage.add(
                world.storage.query[Position]().without[FlexibleComponent[1]](),
                FlexibleComponent[1](1.0, 42.0),
            )
            _ = world.storage.remove[FlexibleComponent[1]](
                world.storage.query[Position, FlexibleComponent[1]]()
            )
        except e:
            print(e)

    bencher.iter(bench_fn)


def benchmark_add_remove_1_comp_1_000_batch_1_000(
    mut bencher: Bencher,
):
    world = SmallWorld()

    try:
        # create 1_000 entities that initially do not have FlexibleComponent[1]
        _ = world.storage.add_entities(Position(1.0, 2.0), count=1_000)
    except e:
        print(e)
        return

    @always_inline
    def bench_fn() {imm, mut world}:
        try:
            # then 1_000 x add component and remove it afterwards
            for _ in range(1000):
                _ = world.storage.add(
                    world.storage.query[Position]().without[
                        FlexibleComponent[1]
                    ](),
                    FlexibleComponent[1](1.0, 42.0),
                )
                _ = world.storage.remove[FlexibleComponent[1]](
                    world.storage.query[Position, FlexibleComponent[1]]()
                )
        except e:
            print(e)

    bencher.iter(bench_fn)


def run_all_world_component_single_batch_benchmarks() raises:
    bench = DefaultBench()
    run_all_world_component_single_batch_benchmarks(bench)
    bench.dump_report()


def run_all_world_component_single_batch_benchmarks(mut bench: Bench) raises:
    bench.bench_function(
        benchmark_add_remove_1_comp_batch_1_000_000,
        BenchId("10^0 * add & remove 1 component 10^6 batch"),
    )
    bench.bench_function(
        benchmark_add_remove_1_comp_1_000_batch_1_000,
        BenchId("10^3 * add & remove 1 component 10^3 batch"),
    )
