from std.benchmark import Bench, Bencher, keep, BenchId
from custom_benchmark import DefaultBench
from larecs.test_utils import *
from larecs.entity import Entity


def benchmark_add_entity_1_000_000(mut bencher: Bencher):
    var world = SmallWorld()

    @always_inline
    def bench_fn() {imm, mut world}:
        try:
            for _ in range(1_000_000):
                keep(world.storage.add_entity().get_id())

        except e:
            print(e)

    bencher.iter(bench_fn)


def benchmark_add_entities_1_000_batch_1_000(
    mut bencher: Bencher,
):
    var world = SmallWorld()

    @always_inline
    def bench_fn() {imm, mut world}:
        try:
            for _ in range(1_000):
                keep(Bool(world.storage.add_entities(count=1000)))

        except e:
            print(e)

    bencher.iter(bench_fn)


def benchmark_add_entity_1_comp_1_000_000(
    mut bencher: Bencher,
):
    var pos = Position(1.0, 2.0)
    var world = SmallWorld()

    @always_inline
    def bench_fn() {imm, mut world}:
        try:
            for _ in range(1_000_000):
                keep(world.storage.add_entity(pos).get_id())
        except e:
            print(e)

    bencher.iter(bench_fn)


def benchmark_add_entities_1_comp_1_000_batch_1_000(
    mut bencher: Bencher,
):
    var pos = Position(1.0, 2.0)
    var world = SmallWorld()

    @always_inline
    def bench_fn() {imm, mut world}:
        try:
            for _ in range(1_000):
                keep(Bool(world.storage.add_entities(pos, count=1000)))

        except e:
            print(e)

    bencher.iter(bench_fn)


def prevent_inlining_add_entity_1_comp() raises:
    var pos = Position(1.0, 2.0)
    var world = SmallWorld()
    _ = world.storage.add_entity(pos)
    _ = world.storage.add_entities(pos, count=1)


def benchmark_add_entities_5_comp_1_000_000(
    mut bencher: Bencher,
):
    var c1 = FlexibleComponent[1](1.0, 2.0)
    var c2 = FlexibleComponent[2](1.0, 2.0)
    var c3 = FlexibleComponent[3](1.0, 2.0)
    var c4 = FlexibleComponent[4](1.0, 2.0)
    var c5 = FlexibleComponent[5](1.0, 2.0)
    var world = SmallWorld()

    @always_inline
    def bench_fn() {imm, mut world}:
        try:
            for _ in range(1_000_000):
                keep(world.storage.add_entity(c1, c2, c3, c4, c5).get_id())

        except e:
            print(e)

    bencher.iter(bench_fn)


def benchmark_add_entity_5_comp_1_000_batch_1_000(
    mut bencher: Bencher,
):
    var c1 = FlexibleComponent[1](1.0, 2.0)
    var c2 = FlexibleComponent[2](1.0, 2.0)
    var c3 = FlexibleComponent[3](1.0, 2.0)
    var c4 = FlexibleComponent[4](1.0, 2.0)
    var c5 = FlexibleComponent[5](1.0, 2.0)
    var world = SmallWorld()

    @always_inline
    def bench_fn() {imm, mut world}:
        try:
            for _ in range(1_000):
                keep(
                    Bool(
                        world.storage.add_entities(
                            c1, c2, c3, c4, c5, count=1000
                        )
                    )
                )

        except e:
            print(e)

    bencher.iter(bench_fn)


def prevent_inlining_add_entity_5_comp() raises:
    var c1 = FlexibleComponent[1](1.0, 2.0)
    var c2 = FlexibleComponent[2](1.0, 2.0)
    var c3 = FlexibleComponent[3](1.0, 2.0)
    var c4 = FlexibleComponent[4](1.0, 2.0)
    var c5 = FlexibleComponent[5](1.0, 2.0)
    var world = SmallWorld()
    _ = world.storage.add_entity(c1, c2, c3, c4, c5)
    _ = world.storage.add_entities(c1, c2, c3, c4, c5, count=1)


def benchmark_add_remove_entity_1_comp_1_000_000(
    mut bencher: Bencher,
):
    var pos = Position(1.0, 2.0)
    var world = SmallWorld()

    @always_inline
    def bench_fn() {imm, mut world}:
        try:
            var entities = List[Entity]()
            for _ in range(1000):
                for _ in range(1000):
                    entities.append(world.storage.add_entity(pos))
                for entity in entities:
                    world.storage.remove_entity(entity)
                entities.clear()

        except e:
            print(e)

    bencher.iter(bench_fn)


def benchmark_add_remove_entities_1_comp_1_000_batch_1000(
    mut bencher: Bencher,
):
    var pos = Position(1.0, 2.0)
    var world = SmallWorld()

    @always_inline
    def bench_fn() {imm, mut world}:
        try:
            for _ in range(1000):
                _ = world.storage.add_entities(pos, count=1000)
                world.storage.remove_entities(world.storage.query[Position]())

        except e:
            print(e)

    bencher.iter(bench_fn)


def prevent_inlining_add_remove_entity_1_comp() raises:
    var pos = Position(1.0, 2.0)
    var world = SmallWorld()
    var entity = world.storage.add_entity(pos)
    world.storage.remove_entity(entity)
    world.storage.remove_entities(world.storage.query[Position]())


def benchmark_add_remove_entity_5_comp_1_000_000(
    mut bencher: Bencher,
):
    var c1 = LargerComponent(1.0, 2.0, 3.0)
    var c2 = FlexibleComponent[2](1.0, 2.0)
    var c3 = FlexibleComponent[3](1.0, 2.0)
    var c4 = FlexibleComponent[4](1.0, 2.0)
    var c5 = FlexibleComponent[5](1.0, 2.0)
    var world = SmallWorld()

    @always_inline
    def bench_fn() {imm, mut world}:
        try:
            _ = world.storage.add_entity(c3, c5)

            var entities = List[Entity]()
            for _ in range(1000):
                for _ in range(1000):
                    entities.append(
                        world.storage.add_entity(c1, c2, c3, c4, c5)
                    )
                var e = world.storage.add_entity(c3, c5)
                for entity in entities:
                    world.storage.remove_entity(entity)
                world.storage.remove_entity(e)
                entities.clear()

        except e:
            print(e)

    bencher.iter(bench_fn)


def benchmark_add_remove_entities_5_comp_1_000_batch_1_000(
    mut bencher: Bencher,
):
    var c1 = LargerComponent(1.0, 2.0, 3.0)
    var c2 = FlexibleComponent[2](1.0, 2.0)
    var c3 = FlexibleComponent[3](1.0, 2.0)
    var c4 = FlexibleComponent[4](1.0, 2.0)
    var c5 = FlexibleComponent[5](1.0, 2.0)
    var world = SmallWorld()

    @always_inline
    def bench_fn() {imm, mut world}:
        try:
            for _ in range(1000):
                _ = world.storage.add_entities(c1, c2, c3, c4, c5, count=1000)
                world.storage.remove_entities(
                    world.storage.query[
                        LargerComponent,
                        FlexibleComponent[2],
                        FlexibleComponent[3],
                        FlexibleComponent[4],
                        FlexibleComponent[5],
                    ]()
                )

        except e:
            print(e)

    bencher.iter(bench_fn)


def prevent_inlining_add_remove_entity_5_comp() raises:
    var c1 = FlexibleComponent[1](1.0, 2.0)
    var c2 = FlexibleComponent[2](1.0, 2.0)
    var c3 = FlexibleComponent[3](1.0, 2.0)
    var c4 = FlexibleComponent[4](1.0, 2.0)
    var c5 = FlexibleComponent[5](1.0, 2.0)

    var world = SmallWorld()
    var entity = world.storage.add_entity(c1, c2, c3, c4, c5)
    world.storage.remove_entity(entity)
    _ = world.storage.add_entity(c1, c2, c3, c4, c5)
    world.storage.remove_entities(
        world.storage.query[
            LargerComponent,
            FlexibleComponent[2],
            FlexibleComponent[3],
            FlexibleComponent[4],
            FlexibleComponent[5],
        ]()
    )


def benchmark_has_1_000_000(mut bencher: Bencher):
    var pos = Position(1.0, 2.0)
    var vel = Velocity(0.1, 0.2)
    var world = SmallWorld()

    @always_inline
    def bench_fn() {imm, mut world}:
        try:
            var entity = world.storage.add_entity(pos, vel)
            for _ in range(1_000_000):
                keep(world.storage.has[Position](entity))

        except e:
            print(e)

    bencher.iter(bench_fn)


def benchmark_is_alive_1_000_000(mut bencher: Bencher):
    var pos = Position(1.0, 2.0)
    var vel = Velocity(0.1, 0.2)
    var world = SmallWorld()

    @always_inline
    def bench_fn() {imm, mut world}:
        try:
            var entity = world.storage.add_entity(pos, vel)
            for _ in range(1_000_000):
                keep(world.storage.is_alive(entity))

        except e:
            print(e)

    bencher.iter(bench_fn)


def run_all_world_entity_benchmarks() raises:
    var bench = DefaultBench()
    run_all_world_entity_benchmarks(bench)
    bench.dump_report()


def run_all_world_entity_benchmarks(mut bench: Bench) raises:
    bench.bench_function(
        benchmark_add_entity_1_000_000, BenchId("10^6 * add_entity")
    )
    bench.bench_function(
        benchmark_add_entities_1_000_batch_1_000,
        BenchId("10^3 * add_entity 1000 batch"),
    )
    bench.bench_function(
        benchmark_add_entity_1_comp_1_000_000,
        BenchId("10^6 * add_entity 1 component"),
    )
    bench.bench_function(
        benchmark_add_entities_1_comp_1_000_batch_1_000,
        BenchId("10^3 * add_entity 1 component 1000 batch"),
    )
    bench.bench_function(
        benchmark_add_entities_5_comp_1_000_000,
        BenchId("10^6 * add_entity 5 components"),
    )
    bench.bench_function(
        benchmark_add_entity_5_comp_1_000_batch_1_000,
        BenchId("10^3 * add_entity 5 components 1000 batch"),
    )
    bench.bench_function(
        benchmark_add_remove_entity_1_comp_1_000_000,
        BenchId("10^6 * add & remove entity (1 component)"),
    )
    bench.bench_function(
        benchmark_add_remove_entities_1_comp_1_000_batch_1000,
        BenchId("10^3 * add & remove entity (1 component) 1000 batch"),
    )
    bench.bench_function(
        benchmark_add_remove_entity_5_comp_1_000_000,
        BenchId("10^6 * add & remove entity (5 components)"),
    )
    bench.bench_function(
        benchmark_add_remove_entities_5_comp_1_000_batch_1_000,
        BenchId("10^3 * add & remove entity (5 components) 1000 batch"),
    )
    bench.bench_function(benchmark_has_1_000_000, BenchId("10^6 * has"))
    bench.bench_function(
        benchmark_is_alive_1_000_000, BenchId("10^6 * is_alive")
    )

    # Functions to prevent inlining
    prevent_inlining_add_remove_entity_1_comp()
    prevent_inlining_add_remove_entity_5_comp()
    prevent_inlining_add_entity_1_comp()
    prevent_inlining_add_entity_5_comp()
