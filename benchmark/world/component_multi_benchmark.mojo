from std.benchmark import Bench, Bencher, BenchId
from custom_benchmark import DefaultBench
from larecs.test_utils import *


def benchmark_add_remove_5_comp_1_000_000(
    mut bencher: Bencher,
):
    c1 = FlexibleComponent[1](1.0, 2.0)
    c2 = FlexibleComponent[2](1.0, 2.0)
    c3 = FlexibleComponent[3](1.0, 2.0)
    c4 = FlexibleComponent[4](1.0, 2.0)
    c5 = FlexibleComponent[5](1.0, 2.0)
    pos = Position(1.0, 2.0)
    world = SmallWorld()

    @always_inline
    def bench_fn() {imm, mut world}:
        try:
            entity = world.storage.add_entity(pos)
            for _ in range(1_000_000):
                world.storage.add(entity, c1, c2, c3, c4, c5)
                world.storage.remove[
                    FlexibleComponent[1],
                    FlexibleComponent[2],
                    FlexibleComponent[3],
                    FlexibleComponent[4],
                    FlexibleComponent[5],
                ](entity)

        except e:
            print(e)

    bencher.iter(bench_fn)


def run_all_world_component_multi_benchmarks() raises:
    bench = DefaultBench()
    run_all_world_component_multi_benchmarks(bench)
    bench.dump_report()


def run_all_world_component_multi_benchmarks(mut bench: Bench) raises:
    bench.bench_function(
        benchmark_add_remove_5_comp_1_000_000,
        BenchId("10^6 * add & remove 5 components"),
    )
