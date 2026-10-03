"""Bounded CPU ECS workloads for same-runner PR regression checks."""

from std.benchmark import keep
from std.time import perf_counter_ns
from larecs import Entity, Filter, KernelContext, SystemContext, World


@fieldwise_init
struct Value(Copyable, Movable):
    """Integer payload whose exact value can be checked after execution."""

    var value: Int


@fieldwise_init
struct Tag(Copyable, Movable):
    """Second component used to vary archetypes and selected composition."""

    var value: Int


def increment(context: KernelContext[Filter().include[Value]()]):
    """Increments each matched row once.

    Args:
        context: Writable value rows for the current CPU invocation.
    """
    for entity in context:
        entity.get[Value]().value += 1


def report(name: String, rows: Int, elapsed: Int, frames: Int):
    """Emits one nanosecond timing record.

    Args:
        name: Stable workload identifier.
        rows: Background or operation row count.
        elapsed: Nanoseconds in the final timed batch.
        frames: Operations in that batch.
    """
    print("CORE", name, rows, Float64(elapsed) / Float64(frames))


def measure_reads[query: Bool](rows: Int) raises:
    """Measures stable-ID access or filtered iteration over two archetypes.

    Parameters:
        query: Use a fresh filtered iterator instead of stable entity IDs.

    Args:
        rows: Number of matching rows; adds equally many excluded rows.

    Raises:
        Error: If setup, access, membership, or checksum validation fails.
    """
    var world = World[Value, Tag]()
    var entities = List[Entity]()
    for i in range(rows):
        if i % 2:
            entities.append(world.storage.add_entity(Value(i), Tag(7)))
        else:
            entities.append(world.storage.add_entity(Value(i)))
        _ = world.storage.add_entity(Tag(9))
    var expected = rows * (rows - 1) // 2
    var frames = 8
    var elapsed: Int
    while True:
        var checksum = 0
        var visited = 0
        var start = perf_counter_ns()
        for _ in range(frames):
            comptime if query:
                for row in world.storage.query[Filter().read[Value]()]():
                    checksum += row.get[Value]().value
                    visited += 1
            else:
                for entity in entities:
                    checksum += world.storage.get[Value](entity).value
                    visited += 1
            keep(checksum)
        elapsed = Int(perf_counter_ns() - start)
        if checksum != frames * expected or visited != frames * rows:
            raise Error("Core read checksum/membership mismatch")
        if elapsed >= 5_000_000 or frames >= 8192:
            break
        frames *= 2
    for i in range(rows):
        if world.storage.get[Value](entities[i]).value != i:
            raise Error("Core read payload/location corruption")
    comptime if query:
        report("query", rows, elapsed, frames)
    else:
        report("access", rows, elapsed, frames)


def measure_execution(rows: Int) raises:
    """Measures ordinary full-world CPU dispatch and row updates.

    Args:
        rows: Number of value rows in the world.

    Raises:
        Error: If creation, execution, or payload validation fails.
    """
    var world = World[Value]()
    for _ in world.storage.add_entities(Value(0), count=rows):
        pass
    var context = SystemContext(world)
    var frames = 8
    var total_frames = 0
    var elapsed: Int
    while True:
        var start = perf_counter_ns()
        for _ in range(frames):
            context.run[increment]()
            keep(len(world))
        elapsed = Int(perf_counter_ns() - start)
        total_frames += frames
        if elapsed >= 5_000_000 or frames >= 8192:
            break
        frames *= 2
    var visited = 0
    for row in world.storage.query[Filter().read[Value]()]():
        if row.get[Value]().value != total_frames:
            raise Error("Core full-world execution mismatch")
        visited += 1
    if visited != rows:
        raise Error("Core full-world membership mismatch")
    report("execute", rows, elapsed, frames)


def measure_selection[mutation: Bool](rows: Int) raises:
    """Measures 64-row execution or partial-archetype component movement.

    Parameters:
        mutation: Add and remove a tag instead of running the increment kernel.

    Args:
        rows: Unselected background rows in the same initial archetype.

    Raises:
        Error: If selection operations, locations, or payload checks fail.
    """
    var world = World[Value, Tag]()
    var entities = List[Entity]()
    for _ in range(rows):
        entities.append(world.storage.add_entity(Value(0)))
    var context = SystemContext(world)
    var selection = context.add_entities(Value(1), count=64)
    var frames = 8
    var total_frames = 0
    var elapsed: Int
    while True:
        var start = perf_counter_ns()
        for _ in range(frames):
            comptime if mutation:
                selection.add(Tag(7))
                selection.remove[Tag]()
                keep(len(selection))
            else:
                selection.run[increment]()
                keep(len(selection))
        elapsed = Int(perf_counter_ns() - start)
        total_frames += frames
        if elapsed >= 5_000_000 or frames >= 8192:
            break
        frames *= 2
    if len(selection) != 64:
        raise Error("Core selection membership mismatch")
    selection^.release()
    var selected_count = 0
    var expected = 1
    comptime if not mutation:
        expected += total_frames
    for row in world.storage.query[Filter().read[Value]()]():
        var value = row.get[Value]().value
        if value == expected:
            selected_count += 1
        elif value != 0:
            raise Error("Core selection payload mismatch")
    if selected_count != 64 or len(world) != rows + 64:
        raise Error("Core selection result mismatch")
    for entity in entities:
        if world.storage.get[Value](entity).value != 0:
            raise Error("Core selection touched background rows")
    for _ in world.storage.query[Filter().read[Tag]()]():
        raise Error("Core selection retained removed tag")
    comptime if mutation:
        report("selected_mutation", rows, elapsed, frames)
    else:
        report("selected_execute", rows, elapsed, frames)


def measure_batch(rows: Int) raises:
    """Measures complete whole-archetype batch creation and removal cycles.

    Args:
        rows: Rows created and removed per cycle.

    Raises:
        Error: If mutation or untouched control-row validation fails.
    """
    var world = World[Value, Tag]()
    var control = world.storage.add_entity(Tag(9))
    # Validate created payload and recycled locations outside the timed region.
    for row in world.storage.add_entities(Value(7), count=rows):
        if row.unsafe_get[Value]().value != 7:
            raise Error("Core batch payload mismatch")
    world.storage.remove_entities[Filter().include[Value]()]()
    var frames = 8
    var elapsed: Int
    while True:
        var start = perf_counter_ns()
        for _ in range(frames):
            _ = world.storage.add_entities(Value(7), count=rows)
            keep(len(world))
            world.storage.remove_entities[Filter().include[Value]()]()
        elapsed = Int(perf_counter_ns() - start)
        if len(world) != 1 or world.storage.get[Tag](control).value != 9:
            raise Error("Core batch removal/control mismatch")
        if elapsed >= 5_000_000 or frames >= 8192:
            break
        frames *= 2
    var visited = 0
    for row in world.storage.add_entities(Value(7), count=rows):
        if row.unsafe_get[Value]().value != 7:
            raise Error("Core recycled batch payload mismatch")
        visited += 1
    if visited != rows:
        raise Error("Core recycled batch membership mismatch")
    world.storage.remove_entities[Filter().include[Value]()]()
    report("batch_cycle", rows, elapsed, frames)


def main() raises:
    """Runs twelve bounded CPU scenarios without importing the full registry.

    Raises:
        Error: If any scenario fails its semantic validation.
    """
    for size in range(2):
        var rows = 512 << (size * 2)
        measure_reads[False](rows)
        measure_reads[True](rows)
        measure_execution(rows)
        measure_selection[False](rows)
        measure_selection[True](rows)
        measure_batch(rows)
