from std.benchmark import Bench, Bencher, BenchId
from custom_benchmark import DefaultBench
from larecs.test_utils import *
from larecs.entity import Entity


def prevent_inlining_replace() raises:
    var pos = Position(1.0, 2.0)
    var vel = Velocity(0.1, 0.2)
    var world = SmallWorld()
    var entity = world.storage.add_entity(pos)
    _ = world.storage.replace[Position]().by(vel, entity=entity)


def _replace_1_comp_workload() raises:
    var world = SmallWorld()
    var entities = List[Entity]()
    var component0 = FlexibleComponent[0](1.0, 2.0)
    for _ in range(1000):
        entities.append(world.storage.add_entity(component0))

    for _ in range(100):
        comptime for i in range(10):
            var component = FlexibleComponent[(i + 1) % 10](Float64(i), 2.0)
            for entity in entities:
                world.storage.replace[FlexibleComponent[i]]().by(
                    component, entity=entity
                )


def benchmark_replace_1_comp_1_000_000(
    mut bencher: Bencher,
):
    @always_inline
    def bench_fn():
        try:
            _replace_1_comp_workload()
        except e:
            print(e)

    bencher.iter(bench_fn)


def run_all_world_replace_single_benchmarks() raises:
    var bench = DefaultBench()
    run_all_world_replace_single_benchmarks(bench)
    bench.dump_report()


def run_all_world_replace_single_benchmarks(mut bench: Bench) raises:
    bench.bench_function(
        benchmark_replace_1_comp_1_000_000,
        BenchId("10^6 * replace 1 component"),
    )
    prevent_inlining_replace()
