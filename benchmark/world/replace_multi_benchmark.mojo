from std.benchmark import Bench, Bencher, BenchId
from custom_benchmark import DefaultBench
from larecs.test_utils import *
from larecs.entity import Entity


def _replace_5_comp_workload() raises:
    var world = FullWorld()
    var entities = List[Entity]()
    for _ in range(1000):
        entities.append(
            world.storage.add_entity(
                FlexibleComponent[0](1.0, 2.0),
                FlexibleComponent[1](3.0, 4.0),
                FlexibleComponent[2](5.0, 6.0),
                FlexibleComponent[3](7.0, 8.0),
                FlexibleComponent[4](9.0, 10.0),
            )
        )
    for _ in range(50):
        comptime for i in range(20):
            comptime base = i * 5
            for entity in entities:
                world.storage.replace[
                    FlexibleComponent[base + 0],
                    FlexibleComponent[base + 1],
                    FlexibleComponent[base + 2],
                    FlexibleComponent[base + 3],
                    FlexibleComponent[base + 4],
                ]().by(
                    FlexibleComponent[(base + 5) % 100](
                        Float64(i) + 11.0, Float32(i) + 12.0
                    ),
                    FlexibleComponent[(base + 6) % 100](
                        Float64(i) + 13.0, Float32(i) + 14.0
                    ),
                    FlexibleComponent[(base + 7) % 100](
                        Float64(i) + 15.0, Float32(i) + 16.0
                    ),
                    FlexibleComponent[(base + 8) % 100](
                        Float64(i) + 17.0, Float32(i) + 18.0
                    ),
                    FlexibleComponent[(base + 9) % 100](
                        Float64(i) + 19.0, Float32(i) + 20.0
                    ),
                    entity=entity,
                )


def benchmark_replace_5_comp_1_000_000(
    mut bencher: Bencher,
):
    @always_inline
    def bench_fn():
        try:
            _replace_5_comp_workload()
        except e:
            print(e)

    bencher.iter(bench_fn)


def run_all_world_replace_multi_benchmarks() raises:
    var bench = DefaultBench()
    run_all_world_replace_multi_benchmarks(bench)
    bench.dump_report()


def run_all_world_replace_multi_benchmarks(mut bench: Bench) raises:
    bench.bench_function(
        benchmark_replace_5_comp_1_000_000,
        BenchId("10^6 * replace 5 components"),
    )
