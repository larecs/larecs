from std.benchmark import Bench, Bencher, BenchId
from custom_benchmark import DefaultBench
from larecs.test_utils import *
from larecs.entity import Entity


def _add_remove_1_comp_workload() raises:
    world = SmallWorld()
    entities = List[Entity]()
    for _ in range(1000):
        entities.append(world.storage.add_entity(FlexibleComponent[0](1.0, 2.0)))

    for _ in range(100):
        comptime for i in range(10):
            for entity in entities:
                world.storage.add(
                    entity, FlexibleComponent[(i + 1) % 10](Float64(i), 2.0)
                )
            for entity in entities:
                world.storage.remove[FlexibleComponent[i]](entity)


def benchmark_add_remove_1_comp_1_000_000(
    mut bencher: Bencher,
):
    @always_inline
    def bench_fn():
        try:
            _add_remove_1_comp_workload()
        except e:
            print(e)

    bencher.iter(bench_fn)


def prevent_inlining_add_remove() raises:
    pos = Position(1.0, 2.0)
    vel = Velocity(0.1, 0.2)
    world = SmallWorld()
    entity = world.storage.add_entity(pos)
    world.storage.add(entity, vel)
    world.storage.remove[Velocity](entity)


def run_all_world_component_single_benchmarks() raises:
    bench = DefaultBench()
    run_all_world_component_single_benchmarks(bench)
    bench.dump_report()


def run_all_world_component_single_benchmarks(mut bench: Bench) raises:
    bench.bench_function(
        benchmark_add_remove_1_comp_1_000_000,
        BenchId("10^6 * add & remove 1 component"),
    )
    prevent_inlining_add_remove()
