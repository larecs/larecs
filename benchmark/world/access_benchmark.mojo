from std.benchmark import Bench, Bencher, keep, BenchId
from std.math import exp
from custom_benchmark import DefaultBench
from larecs.test_utils import *
from larecs import MutableEntityAccessor


def benchmark_get_1_000_000(mut bencher: Bencher):
    pos = Position(1.0, 2.0)
    vel = Velocity(0.1, 0.2)
    world = SmallWorld()

    @always_inline
    def bench_fn() {imm, mut world}:
        try:
            entity = world.add_entity(pos, vel)
            for _ in range(1_000_000):
                keep(world.get[Position](entity).x)

        except e:
            print(e)

    bencher.iter(bench_fn)


def prevent_inlining_get() raises:
    pos = Position(1.0, 2.0)
    vel = Velocity(0.1, 0.2)
    world = SmallWorld()
    entity = world.add_entity(pos, vel)
    keep(world.get[Position](entity).x)


def benchmark_set_1_comp_1_000_000(mut bencher: Bencher):
    pos = Position(1.0, 2.0)
    pos2 = Position(2.0, 2.0)
    vel = Velocity(0.1, 0.2)
    world = SmallWorld()

    @always_inline
    def bench_fn() {imm, mut world}:
        try:
            entity = world.add_entity(pos, vel)
            for _ in range(500_000):
                world.set(entity, pos2)
                world.set(entity, pos)

        except e:
            print(e)

    bencher.iter(bench_fn)


def prevent_inlining_set_1_comp() raises:
    pos = Position(1.0, 2.0)
    pos2 = Position(2.0, 2.0)
    vel = Velocity(0.1, 0.2)
    world = SmallWorld()
    entity = world.add_entity(pos, vel)
    world.set(entity, pos2)
    world.set(entity, pos)


def benchmark_set_5_comp_1_000_000(
    mut bencher: Bencher,
):
    c1 = FlexibleComponent[1](1.0, 2.0)
    c2 = FlexibleComponent[2](1.0, 2.0)
    c3 = FlexibleComponent[3](1.0, 2.0)
    c4 = FlexibleComponent[4](1.0, 2.0)
    c5 = FlexibleComponent[5](1.0, 2.0)

    c1_2 = FlexibleComponent[1](2.0, 4.0)
    c2_2 = FlexibleComponent[2](2.0, 4.0)
    c3_2 = FlexibleComponent[3](2.0, 4.0)
    c4_2 = FlexibleComponent[4](2.0, 4.0)
    c5_2 = FlexibleComponent[5](2.0, 4.0)
    world = SmallWorld()

    @always_inline
    def bench_fn() {imm, mut world}:
        try:
            entity = world.add_entity(c1, c2, c3, c4, c5)
            for _ in range(500_000):
                world.set(entity, c1_2, c2_2, c3_2, c4_2, c5_2)
                world.set(entity, c1, c2, c3, c4, c5)

        except e:
            print(e)

    bencher.iter(bench_fn)


def prevent_inlining_set_5_comp() raises:
    c1 = FlexibleComponent[1](1.0, 2.0)
    c2 = FlexibleComponent[2](1.0, 2.0)
    c3 = FlexibleComponent[3](1.0, 2.0)
    c4 = FlexibleComponent[4](1.0, 2.0)
    c5 = FlexibleComponent[5](1.0, 2.0)

    c1_2 = FlexibleComponent[1](2.0, 4.0)
    c2_2 = FlexibleComponent[2](2.0, 4.0)
    c3_2 = FlexibleComponent[3](2.0, 4.0)
    c4_2 = FlexibleComponent[4](2.0, 4.0)
    c5_2 = FlexibleComponent[5](2.0, 4.0)

    world = SmallWorld()
    entity = world.add_entity(c1, c2, c3, c4, c5)
    world.set(entity, c1_2, c2_2, c3_2, c4_2, c5_2)
    world.set(entity, c1, c2, c3, c4, c5)


def benchmark_apply_expexp_1_comp_100_000(
    mut bencher: Bencher,
):
    pos = Position(1.0, 2.0)
    vel = Velocity(0.1, 0.2)
    world = SmallWorld()

    @always_inline
    def bench_fn() {imm, mut world}:
        try:
            for _ in range(1_000):
                _ = world.add_entity(pos, vel)

            @always_inline
            def operation_plus(accessor: MutableEntityAccessor):
                try:
                    ref pos2 = accessor.get[Position]()
                    pos2.x = exp(1 - exp(pos2.x))
                    pos2.y = exp(1 - exp(pos2.y))
                except:
                    pass

            for _ in range(100):
                world.apply[unroll_factor=3](
                    world.query[Position](), operation_plus
                )

        except e:
            print(e)

    bencher.iter(bench_fn)


# def benchmark_apply_simd_expexp_1_comp_100_000(
#     mut bencher: Bencher,
# ):
#     pos = Position(1.0, 2.0)
#     vel = Velocity(0.1, 0.2)
#     world = SmallWorld()

#     @always_inline
#     def bench_fn() {imm, mut world}:
#         try:
#             for _ in range(1_000):
#                 _ = world.add_entity(pos, vel)

#             @always_inline
#             def operation_plus[
#                 simd_width: Int
#             ](accessor: MutableEntityAccessor):
#                 comptime _load = load2[simd_width]
#                 comptime _store = store2[simd_width]

#                 try:
#                     ref pos2 = accessor.get[Position]()
#                     _store(pos2.x, exp(1 - exp(_load(pos2.x))))
#                     _store(pos2.y, exp(1 - exp(_load(pos2.y))))
#                 except:
#                     return

#             for _ in range(100):
#                 world.apply[
#                     simd_width=16,
#                     unroll_factor=3,
#                 ](world.query[Position, Velocity](), operation_plus)

#         except e:
#             print(e)

#     bencher.iter(bench_fn)


def run_all_world_access_benchmarks() raises:
    bench = DefaultBench()
    run_all_world_access_benchmarks(bench)
    bench.dump_report()


def run_all_world_access_benchmarks(mut bench: Bench) raises:
    bench.bench_function(benchmark_get_1_000_000, BenchId("10^6 * get"))
    bench.bench_function(
        benchmark_set_1_comp_1_000_000, BenchId("10^6 * set 1 component")
    )
    bench.bench_function(
        benchmark_set_5_comp_1_000_000, BenchId("10^6 * set 5 components")
    )
    # bench.bench_function(
    #     benchmark_apply_expexp_1_comp_100_000,
    #     BenchId("10^5 * get and set exp(exp) via apply 1 component"),
    # )
    bench.bench_function(
        benchmark_apply_simd_expexp_1_comp_100_000,
        BenchId("10^5 * get and set exp(exp) via apply simd 1 component"),
    )

    # Functions to prevent inlining
    prevent_inlining_get()
    prevent_inlining_set_1_comp()
    prevent_inlining_set_5_comp()
