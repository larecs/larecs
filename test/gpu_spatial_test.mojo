# SKIP_ASAN
# SKIP_DEBUG

"""CPU/GPU execution and host copy-back after spatial maintenance."""

from std.sys import has_accelerator
from std.testing import assert_equal, assert_false, TestSuite
from larecs import (
    World,
    Filter,
    SpatialClassifier,
    SystemContext,
    KernelContext,
)
from larecs.entity import EntityAccessor


@fieldwise_init
struct Position(Copyable, TrivialRegisterPassable):
    """GPU-safe classifier input and writable kernel column."""

    var value: Int32


@fieldwise_init
struct Payload(Copyable, TrivialRegisterPassable):
    """Column moved together with positions but not used for classification."""

    var value: Int32


comptime spatial_filter = Filter().read[Position]()


@fieldwise_init
struct Policy(SpatialClassifier):
    """Nonnegative test positions are ordered by their value."""

    comptime Accessor = EntityAccessor[spatial_filter]

    def classify(self, entity: Self.Accessor) raises -> UInt64:
        """Returns a value-based key.

        Args:
            entity: Position accessor for one host row.

        Raises:
            Error: The classifier interface permits errors; this policy does
                not raise recoverable errors.

        Returns:
            The position as an unsigned ordering key.
        """
        return UInt64(entity.get[Position]().value)


def update(context: KernelContext[Filter().include[Position, Payload]()]):
    """Reverses positions and updates the associated payload.

    Args:
        context: Component columns on either execution target.
    """
    for entity in context:
        entity.get[Position]().value = 10 - entity.get[Position]().value
        entity.get[Payload]().value += 1


def _check_execution[on_gpu: Bool, selected: Bool = False]() raises:
    """Maintains rows before and after execution and checks copied-back values.

    Parameters:
        on_gpu: Whether to run on the actual accelerator.
        selected: Whether to execute through an exact selection.

    Raises:
        Error: If execution, maintenance, or validation fails.
    """
    var world = World[Position, Payload]()
    var a = world.storage.add_entity(Position(3), Payload(30))
    var b = world.storage.add_entity(Position(1), Payload(10))
    var untouched = world.storage.add_entity(Position(0))
    world.register_spatial_classifier[spatial_filter](Policy())
    world.maintain_spatial()
    var index = world.storage._entity_locations[a.get_id()].archetype_index
    assert_equal(world.storage._archetypes[index].get_entity(0), b)
    var context = SystemContext(world)
    comptime if selected:
        var selection = context._select[Filter().include[Payload]()]()
        selection.run[update, on_gpu=on_gpu]()
        selection^.release()
    else:
        context.run[update, on_gpu=on_gpu]()
    # Read through queries so the test cannot mask missing copy-back invalidation.
    for row in context.world[].storage.query[
        Filter().read[Position, Payload]()
    ]():
        var expected = Int32(7 if row.get_entity() == a else 9)
        assert_equal(row.get[Position]().value, expected)
    assert_equal(context.world[].storage._archetypes[index].get_entity(0), b)
    context.world[].maintain_spatial()
    assert_equal(context.world[].storage._archetypes[index].get_entity(0), a)
    comptime if selected:
        var selection = context._select[Filter().include[Payload]()]()
        selection.run[update, on_gpu=on_gpu]()
        selection^.release()
    else:
        context.run[update, on_gpu=on_gpu]()
    assert_equal(context.world[].storage.get[Position](a).value, 3)
    assert_equal(context.world[].storage.get[Payload](a).value, 32)
    assert_equal(context.world[].storage.get[Position](b).value, 1)
    assert_equal(context.world[].storage.get[Payload](b).value, 12)
    for row in context.world[].storage.query[
        Filter().read[Position]().exclude[Payload]()
    ]():
        assert_equal(row.get_entity(), untouched)
        assert_equal(row.get[Position]().value, Int32(0))
    assert_false(context.world[].storage.is_locked())


def test_cpu_execution_after_spatial_maintenance() raises:
    """Runs the same kernel on CPU before and after reordering.

    Raises:
        Error: If validation fails.
    """
    _check_execution[False]()
    _check_execution[False, True]()


def test_gpu_execution_after_spatial_maintenance() raises:
    """Exercises real GPU upload and copy-back when an accelerator is available.

    Raises:
        Error: If validation fails.
    """
    comptime if not has_accelerator():
        print("SKIP: spatial GPU execution; no accelerator support")
        return
    else:
        var probe = World[Position, Payload]()
        if not probe._device_storage:
            print("SKIP: spatial GPU execution; no working device")
            return
        _check_execution[True]()
        _check_execution[True, True]()
        print("Executed spatial maintenance integration on actual GPU")


def _check_partition_execution[on_gpu: Bool, selected: Bool]() raises:
    """Execute across many blocks, then repartition copied-back inputs.

    Parameters:
        on_gpu: Run on a real accelerator when true.
        selected: Use an exact multi-block selection when true.

    Raises:
        Error: If CPU/GPU execution, transfers, or membership checks fail.
    """
    var world = World[Position, Payload]()
    for i in range(73):
        _ = world.storage.add_entity(Position(Int32(i % 3)), Payload(Int32(i)))
    _ = world.storage.add_entity(Position(1))
    world.register_spatial_classifier[spatial_filter](
        Policy(), partitioned=True, block_capacity=8
    )
    world.maintain_spatial()
    var context = SystemContext(world)
    for frame in range(2):
        comptime if selected:
            var selection = context.select_cluster[Filter().include[Payload]()](
                UInt64(1 if frame == 0 else 9)
            )
            assert_equal(len(selection), 24)
            selection.run[update, on_gpu=on_gpu]()
            selection^.release()
        else:
            context.run[update, on_gpu=on_gpu]()
        for row in context.world[].storage.query[
            Filter().read[Position, Payload]()
        ]():
            var i = Int(row.get_entity().get_id()) - 1
            var affected = i % 3 == 1 if selected else True
            assert_equal(
                row.get[Payload]().value,
                Int32(i + (frame + 1 if affected else 0)),
            )
            assert_equal(
                row.get[Position]().value,
                Int32(10 - i % 3 if frame == 0 and affected else i % 3),
            )
        assert_equal(
            len(context.world[].storage._spatial_dirty), 24 if selected else 73
        )
        context.world[].maintain_spatial()
        for row in context.world[].storage.query[Filter().read[Position]()]():
            var location = context.world[].storage._entity_locations[
                row.get_entity().get_id()
            ]
            ref block = context.world[].storage._archetypes[
                location.archetype_index
            ]
            assert_equal(
                block.get_entity(location.entity_index), row.get_entity()
            )
            assert_equal(
                block._partition_key.value(), UInt64(row.get[Position]().value)
            )
    assert_false(context.world[].storage.is_locked())


def test_partition_cpu_and_gpu_execution() raises:
    """Cover ordinary/selected packing and copy-back across cluster blocks.

    Raises:
        Error: If execution or validation fails.
    """
    _check_partition_execution[False, False]()
    _check_partition_execution[False, True]()
    comptime if has_accelerator():
        var probe = World[Position, Payload]()
        if probe._device_storage:
            _check_partition_execution[True, False]()
            _check_partition_execution[True, True]()
            print("Executed partitioned storage on actual GPU")
        else:
            print("SKIP: partitioned GPU execution; no working device")
    else:
        print("SKIP: partitioned GPU execution; no accelerator support")


def main() raises:
    """Runs spatial execution integration tests.

    Raises:
        Error: If a test fails.
    """
    TestSuite.discover_tests[__functions_in_module()]().run()
