"""Focused CPU dispatch benchmark for both SystemContext.run overloads.

Build with `pixi run mojo build --lld-path /usr/bin/ld -I src
benchmark/cpu_system_benchmark.mojo -o /tmp/larecs-cpu-system`, then run the
binary repeatedly. Each line reports nanoseconds per dispatch, including
component iteration, for seven independently timed batches after warmup.
"""

from std.benchmark import keep
from std.time import perf_counter_ns
from std.testing import assert_equal
from larecs import Filter, KernelContext, SystemContext, World


@fieldwise_init
struct Value(Copyable):
    var value: Int


@fieldwise_init
struct Tag[ID: Int](Copyable):
    var value: Int


comptime FILTER = Filter().include[Value]()


def increment(context: KernelContext[FILTER]):
    """Increments each row's value.

    Args:
        context: The current archetype's component columns.
    """
    for entity in context:
        entity.get[Value]().value += 1


def measure[archetypes: Int, rows: Int, use_closure: Bool]() raises:
    """Times repeated CPU dispatches without setup or compilation costs.

    Parameters:
        archetypes: Number of matching archetypes, from zero to three.
        rows: Rows per matching archetype.
        use_closure: Whether to use the closure overload.

    Raises:
        Error: If population or dispatch fails.
    """
    var world = World[Value, Tag[0], Tag[1]]()
    comptime if archetypes > 0:
        for _ in world.storage.add_entities(Value(0), count=rows):
            pass
    comptime if archetypes > 1:
        for _ in world.storage.add_entities(Value(0), Tag[0](0), count=rows):
            pass
    comptime if archetypes > 2:
        for _ in world.storage.add_entities(Value(0), Tag[1](0), count=rows):
            pass
    var context = SystemContext(world)
    var delta = 1

    def captured(context: KernelContext[FILTER]) {imm delta}:
        """Increments rows by a captured value.

        Args:
            context: The current archetype's component columns.
        """
        for entity in context:
            entity.get[Value]().value += delta

    comptime iterations = 1000
    for batch in range(8):
        var start = perf_counter_ns()
        for _ in range(iterations):
            comptime if use_closure:
                context.run(captured)
            else:
                context.run[increment]()
        var elapsed = perf_counter_ns() - start
        keep(world)
        if batch > 0:
            print(archetypes, rows, use_closure, Float64(elapsed) / iterations)

    var count = 0
    var checksum = 0
    for entity in world.storage.query[FILTER]():
        var value = entity.get[Value]().value
        assert_equal(value, 8 * iterations)
        checksum += value
        count += 1
    assert_equal(count, archetypes * rows)
    assert_equal(checksum, archetypes * rows * 8 * iterations)
    keep(checksum)


def main() raises:
    """Prints dispatch timings for empty, small, and larger CPU worlds.

    Raises:
        Error: If a benchmark case fails.
    """
    comptime for use_closure in range(2):
        measure[0, 0, Bool(use_closure)]()
        measure[1, 8, Bool(use_closure)]()
        measure[3, 8, Bool(use_closure)]()
        measure[1, 4096, Bool(use_closure)]()
        measure[3, 4096, Bool(use_closure)]()
