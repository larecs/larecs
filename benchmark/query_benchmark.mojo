from std.benchmark import Bench, BenchConfig, Bencher, keep, BenchId
from custom_benchmark import DefaultBench
from larecs.world import World
from larecs.entity import Entity
from larecs.component import ComponentType
from larecs.test_utils import *


def benchmark_add_entity_1_000_000(mut bencher: Bencher):
    world = SmallWorld()

    @always_inline
    def bench_fn() {mut world}:
        try:
            for _ in range(1_000_000):
                keep(world.storage.add_entity().get_id())

        except e:
            print(e)

    bencher.iter(bench_fn)


def benchmark_query_1_comp_1_000_000(
    mut bencher: Bencher,
):
    pos = Position(1.0, 2.0)
    world = SmallWorld()

    @always_inline
    def bench_fn() {imm, mut world}:
        try:
            for _ in range(1000):
                _ = world.storage.add_entity(pos)
            for _ in range(1000):
                for entity in world.storage.query[Position]():
                    keep(entity.get[Position]().x)
        except e:
            print(e)

    bencher.iter(bench_fn)


def benchmark_query_2_comp_1_000_000(
    mut bencher: Bencher,
):
    pos = Position(1.0, 2.0)
    vel = Velocity(0.1, 0.2)
    world = SmallWorld()

    @always_inline
    def bench_fn() {imm, mut world}:
        try:
            for _ in range(1000):
                _ = world.storage.add_entity(pos, vel)
            for _ in range(1000):
                for entity in world.storage.query[Position, Velocity]():
                    keep(entity.get[Position]().x)
                    keep(entity.get[Velocity]().dx)

        except e:
            print(e)

    bencher.iter(bench_fn)


def benchmark_query_5_comp_1_000_000(
    mut bencher: Bencher,
):
    c1 = FlexibleComponent[1](3.0, 4.0)
    c2 = FlexibleComponent[2](5.0, 6.0)
    c3 = FlexibleComponent[3](7.0, 8.0)
    c4 = FlexibleComponent[4](9.0, 10.0)
    c5 = FlexibleComponent[5](11.0, 12.0)
    world = FullWorld()

    @always_inline
    def bench_fn() {imm, mut world}:
        try:
            for _ in range(1000):
                _ = world.storage.add_entity(c1, c2, c3, c4, c5)
            for _ in range(1000):
                for entity in world.storage.query[
                    FlexibleComponent[1],
                    FlexibleComponent[2],
                    FlexibleComponent[3],
                    FlexibleComponent[4],
                    FlexibleComponent[5],
                ]():
                    keep(entity.get[FlexibleComponent[1]]().x)
                    keep(entity.get[FlexibleComponent[2]]().x)
                    keep(entity.get[FlexibleComponent[3]]().x)
                    keep(entity.get[FlexibleComponent[4]]().x)
                    keep(entity.get[FlexibleComponent[5]]().x)

        except e:
            print(e)

    bencher.iter(bench_fn)


def benchmark_query_get_iter_1_000_000(
    mut bencher: Bencher,
):
    c1 = FlexibleComponent[1](3.0, 4.0)
    c2 = FlexibleComponent[2](5.0, 6.0)
    c3 = FlexibleComponent[3](7.0, 8.0)
    c4 = FlexibleComponent[4](9.0, 10.0)
    c5 = FlexibleComponent[5](11.0, 12.0)
    world = FullWorld()

    @always_inline
    def bench_fn() {imm, mut world}:
        try:
            _ = world.storage.add_entity(c1, c2, c3, c4, c5)
            for _ in range(1_000_000):
                keep(world.storage.query[FlexibleComponent[1]]().__iter__()._lock)

        except e:
            print(e)

    bencher.iter(bench_fn)


def benchmark_query_has_1_000_000(
    mut bencher: Bencher,
):
    c1 = FlexibleComponent[1](3.0, 4.0)
    c2 = FlexibleComponent[2](5.0, 6.0)
    c3 = FlexibleComponent[3](7.0, 8.0)
    c4 = FlexibleComponent[4](9.0, 10.0)
    c5 = FlexibleComponent[5](11.0, 12.0)
    world = FullWorld()

    @always_inline
    def bench_fn() {imm, mut world}:
        try:
            _ = world.storage.add_entity(c1, c2, c3, c4, c5)
            for entity in world.storage.query[FlexibleComponent[1]]():
                for _ in range(1_000_000):
                    keep(entity.has[FlexibleComponent[1]]())

        except e:
            print(e)

    bencher.iter(bench_fn)


def run_all_query_benchmarks() raises:
    bench = DefaultBench()
    run_all_query_benchmarks(bench)
    bench.dump_report()


def run_all_query_benchmarks(mut bench: Bench) raises:
    bench.bench_function(
        benchmark_query_has_1_000_000, BenchId("10^6 * query has")
    )
    bench.bench_function(
        benchmark_query_1_comp_1_000_000, BenchId("10^6 * query & get 1 comp")
    )
    bench.bench_function(
        benchmark_query_2_comp_1_000_000, BenchId("10^6 * query & get 2 comp")
    )
    bench.bench_function(
        benchmark_query_5_comp_1_000_000, BenchId("10^6 * query & get 5 comp")
    )
    bench.bench_function(
        benchmark_query_get_iter_1_000_000, BenchId("10^6 * get query iter")
    )


def main() raises:
    run_all_query_benchmarks()
