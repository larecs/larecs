"""Benchmarks exact selected execution and mutation in a large world."""

from std.benchmark import Bench, BenchId, Bencher, keep
from std.os import abort
from std.sys import has_accelerator

from custom_benchmark import DefaultBench
from larecs import EntityRange, Filter, KernelContext, SystemContext, World


@fieldwise_init
struct Value(Copyable, TrivialRegisterPassable):
    """GPU-safe benchmark value."""

    var value: Float32


@fieldwise_init
struct SelectedTag(Copyable, TrivialRegisterPassable):
    """Component toggled by the selected mutation benchmark."""

    var value: Int32


comptime WORLD_SIZE = 100_000
"""Number of unselected rows in each benchmark world."""

comptime SELECTION_SIZE = 64
"""Number of rows in the small selected batch."""


def increment(context: KernelContext[Filter().include[Value]()]):
    """Increments every execution row.

    Args:
        context: Value rows for this execution range or packed GPU launch.
    """
    for entity in context:
        entity.get[Value]().value += 1.0


def _populate(mut world: World[Value, SelectedTag]) raises:
    """Populates the large unselected prefix.

    Args:
        world: World to populate.

    Raises:
        Error: If batch creation fails.
    """
    for _ in world.storage.add_entities(Value(0.0), count=WORLD_SIZE):
        pass


def _bench_full_world(mut bencher: Bencher):
    """Measures the unchanged ordinary full-world CPU path.

    Args:
        bencher: Benchmark driver.

    """
    try:
        var world = World[Value, SelectedTag]()
        _populate(world)
        var context = SystemContext(world)

        def run_once() {mut context}:
            try:
                context.run[increment]()
            except e:
                print(e)
                abort("Entity selection benchmark workload failed")

        bencher.iter(run_once)
    except e:
        print(e)
        abort("Entity selection benchmark setup failed")


@fieldwise_init
struct ArchetypeTag[index: Int](Copyable, TrivialRegisterPassable):
    """Creates distinct archetypes without changing kernel work."""

    var value: Int32


def _bench_many_archetypes[closure: Bool](mut bencher: Bencher):
    """Measures lazy CPU discovery across matching and nonmatching archetypes.

    Parameters:
        closure: Whether to invoke a lexical closure or thin kernel.

    Args:
        bencher: Benchmark driver; setup and verification are outside timing.
    """
    try:
        var world = World[
            Value,
            ArchetypeTag[0],
            ArchetypeTag[1],
            ArchetypeTag[2],
            ArchetypeTag[3],
            ArchetypeTag[4],
            ArchetypeTag[5],
        ]()
        comptime for i in range(6):
            for _ in world.storage.add_entities(
                Value(0.0), ArchetypeTag[i](0), count=512
            ):
                pass
            for _ in world.storage.add_entities(ArchetypeTag[i](0), count=512):
                pass
        for _ in world.storage.add_entities(Value(0.0), count=512):
            pass
        var context = SystemContext(world)
        var calls = 0

        def lexical_kernel(
            rows: KernelContext[Filter().include[Value]()],
        ) {mut calls}:
            """Runs identical row work and retains one lexical invocation count.

            Args:
                rows: One matching archetype's Value column.
            """
            calls += 1
            increment(rows)

        def run_once() {mut context, imm lexical_kernel}:
            try:
                comptime if closure:
                    context.run(lexical_kernel)
                else:
                    context.run[increment]()
            except e:
                print(e)
                abort("Multi-archetype CPU benchmark workload failed")

        bencher.iter(run_once)
        var count = 0
        var total = Float32(0)
        for row in world.storage.query[Filter().read[Value]()]():
            count += 1
            total += row.get[Value]().value
        if count != 3584 or total <= 0:
            abort("Multi-archetype CPU benchmark validation failed")
        comptime if closure:
            if total != Float32(calls * 512):
                abort("Multi-archetype closure benchmark visit count failed")
        keep(total)
    except e:
        print(e)
        abort("Multi-archetype CPU benchmark setup failed")


def _bench_contiguous_selection[on_gpu: Bool](mut bencher: Bencher):
    """Measures repeated execution on one small contiguous selection.

    Parameters:
        on_gpu: Whether to execute on the accelerator.

    Args:
        bencher: Benchmark driver.

    """
    try:
        var world = World[Value, SelectedTag]()
        _populate(world)
        var context = SystemContext(world)
        var selection = context.add_entities(Value(1.0), count=SELECTION_SIZE)

        def run_once() {mut selection}:
            try:
                selection.run[increment, on_gpu=on_gpu]()
                keep(len(selection))
            except e:
                print(e)
                abort("Entity selection benchmark workload failed")

        bencher.iter(run_once)
    except e:
        print(e)
        abort("Entity selection benchmark setup failed")


def _bench_disjoint_selection(mut bencher: Bencher):
    """Measures repeated CPU execution over disjoint single-row ranges.

    Args:
        bencher: Benchmark driver.
    """
    try:
        var world = World[Value, SelectedTag]()
        _populate(world)
        var context = SystemContext(world)
        var selection = context._empty_selection()
        for i in range(SELECTION_SIZE):
            selection._ranges.append(EntityRange(1, i * 2, 1))

        def run_once() {mut selection}:
            try:
                selection.run[increment]()
                keep(len(selection))
            except e:
                print(e)
                abort("Entity selection benchmark workload failed")

        bencher.iter(run_once)
    except e:
        print(e)
        abort("Entity selection benchmark setup failed")


def _bench_selected_mutation_chain(mut bencher: Bencher):
    """Measures repeated in-place add/remove operations under one guard.

    Args:
        bencher: Benchmark driver.

    """
    try:
        var world = World[Value, SelectedTag]()
        _populate(world)
        var context = SystemContext(world)
        var selection = context.add_entities(Value(1.0), count=SELECTION_SIZE)

        def run_once() {mut selection}:
            try:
                selection.add(SelectedTag(1))
                selection.remove[SelectedTag]()
                keep(len(selection))
            except e:
                print(e)
                abort("Entity selection benchmark workload failed")

        bencher.iter(run_once)
    except e:
        print(e)
        abort("Entity selection benchmark setup failed")


def _bench_large_disjoint_mutation(mut bencher: Bencher):
    """Measures mutation of many disjoint, reverse-ordered selected rows.

    Args:
        bencher: Benchmark driver.
    """
    try:
        var world = World[Value, SelectedTag]()
        _populate(world)
        var context = SystemContext(world)
        var selection = context._empty_selection()
        for i in range(512):
            selection._ranges.append(EntityRange(1, (511 - i) * 2, 1))

        def run_once() {mut selection}:
            try:
                selection.add(SelectedTag(1))
                selection.remove[SelectedTag]()
                keep(len(selection))
            except e:
                print(e)
                abort("Entity selection benchmark workload failed")

        bencher.iter(run_once)
    except e:
        print(e)
        abort("Entity selection benchmark setup failed")


def run_all_entity_selection_benchmarks(mut bench: Bench) raises:
    """Registers selected and ordinary execution benchmarks.

    Args:
        bench: Benchmark registry.

    Raises:
        Error: If benchmark registration fails.
    """
    bench.bench_function(
        _bench_full_world,
        BenchId("system cpu, full world 100k"),
        fixed_iterations=100,
    )
    bench.bench_function(
        _bench_many_archetypes[False],
        BenchId("system cpu, 7 matching of 13 archetypes thin"),
        fixed_iterations=1000,
    )
    bench.bench_function(
        _bench_many_archetypes[True],
        BenchId("system cpu, 7 matching of 13 archetypes closure"),
        fixed_iterations=1000,
    )
    bench.bench_function(
        _bench_contiguous_selection[False],
        BenchId("selection cpu, 64 of 100k contiguous"),
        fixed_iterations=10_000,
    )
    bench.bench_function(
        _bench_disjoint_selection,
        BenchId("selection cpu, 64 of 100k disjoint"),
        fixed_iterations=1_000,
    )
    bench.bench_function(
        _bench_selected_mutation_chain,
        BenchId("selection cpu, 64 add/remove chain"),
        fixed_iterations=100,
    )
    bench.bench_function(
        _bench_large_disjoint_mutation,
        BenchId("selection cpu, 512 disjoint add/remove first pass"),
        fixed_iterations=1,
    )
    comptime if has_accelerator():
        bench.bench_function(
            _bench_contiguous_selection[True],
            BenchId("selection gpu, 64 of 100k contiguous"),
            fixed_iterations=100,
        )


def main() raises:
    """Runs the entity-selection benchmark standalone.

    Raises:
        Error: If a benchmark fails.
    """
    var bench = DefaultBench()
    run_all_entity_selection_benchmarks(bench)
    bench.dump_report()
