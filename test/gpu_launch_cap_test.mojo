# SKIP_ASAN
# SKIP_DEBUG

"""Hardware tests for systems launched with fewer threads than rows."""

from std.sys import has_accelerator
from std.testing import assert_equal, TestSuite

from larecs import Entity, Filter, KernelContext, SystemContext, World
from larecs.gpu_launch import BLOCK_SIZE


@fieldwise_init
struct Position(Copyable, TrivialRegisterPassable):
    """Device-safe scalar position."""

    var value: Float32


comptime ROW_COUNT = 3 * BLOCK_SIZE + 5
"""Rows per test: several full blocks plus a final partial block."""

comptime GRID_CAP = 2
"""Forced grid cap, so each launched thread covers more than one row."""


def add_one(context: KernelContext[Filter().include[Position]()]):
    """Adds one to each position.

    Args:
        context: The position rows.
    """
    for entity in context:
        entity.get[Position]().value += 1.0


def _capped_world(mut entities: List[Entity]) raises -> World[Position]:
    """Creates a world with `ROW_COUNT` rows and a forced grid cap.

    Row ``i`` stores position ``i``, so every row has a distinct value.

    Args:
        entities: Receives the created entities in row order.

    Raises:
        Error: If the entities cannot be added.

    Returns:
        The populated world.
    """
    var world = World[Position]()
    world._device_storage.value()._max_grid_dim = GRID_CAP
    for i in range(ROW_COUNT):
        entities.append(world.storage.add_entity(Position(Float32(i))))
    return world^


def _assert_each_row_incremented_once(
    mut world: World[Position], entities: List[Entity]
) raises:
    """Checks that every row was incremented exactly once.

    Args:
        world: The world the system ran on.
        entities: The entities in row order.

    Raises:
        Error: If any row was skipped or processed twice.
    """
    for i in range(len(entities)):
        assert_equal(
            world.storage.get[Position](entities[i]).value, Float32(i + 1)
        )


def test_capped_system_run_covers_every_row() raises:
    """A capped `SystemContext.run` launch processes every row exactly once.

    Raises:
        Error: If device execution or an assertion fails.
    """
    comptime if has_accelerator():
        var entities = List[Entity]()
        var world = _capped_world(entities)
        var context = SystemContext(world)
        context.run[add_one, on_device=True]()
        _assert_each_row_incremented_once(world, entities)


def test_capped_selection_run_covers_every_row() raises:
    """A capped selection launch processes every selected row exactly once.

    Raises:
        Error: If device execution or an assertion fails.
    """
    comptime if has_accelerator():
        var entities = List[Entity]()
        var world = _capped_world(entities)
        var context = SystemContext(world)
        var selection = context.add_entities(Position(-10.0), count=ROW_COUNT)
        selection.run[add_one, on_device=True]()
        selection^.release()

        for i in range(len(entities)):
            assert_equal(
                world.storage.get[Position](entities[i]).value, Float32(i)
            )
        var selected_rows = 0
        for row in world.storage.query[Filter().include[Position]()]():
            if row.get[Position]().value == -9.0:
                selected_rows += 1
        assert_equal(selected_rows, ROW_COUNT)


def main() raises:
    """Runs capped launch tests.

    Raises:
        Error: If any discovered test fails.
    """
    TestSuite.discover_tests[__functions_in_module()]().run()
