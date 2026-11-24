# MOJO_BUILD_ARGS: -g1

"""HostStorage row permutation and spatial maintenance tests."""

from std.testing import *

from larecs.host_storage import HostStorage
from larecs import World, SpatialClassifier
from larecs.entity import EntityAccessor
from larecs.entity import Entity
from larecs.filter import Filter
from larecs.error import WorldError
from larecs.test_utils import *

from fixtures.lifecycle import LifecycleCounters, TrackedComponent


def test_reorder_rows_preserves_values_and_locations() raises:
    """Permute cycles across all columns, including owned heap values.

    Raises:
        Error: If storage setup, row reordering, or an assertion fails.
    """
    var storage = HostStorage[Int, String, Float64]()
    var entities = List[Entity]()
    for row in range(6):
        entities.append(storage.add_entity(row, String(row), Float64(row + 10)))
    var unrelated = storage.add_entity(99)
    var index = storage._entity_locations[entities[0].get_id()].archetype_index
    var mask = storage._archetypes[index].get_mask().copy()
    var count = len(storage._archetypes)
    # One three-cycle, one two-cycle, and a fixed row.
    var order: List[Int] = [2, 0, 1, 4, 3, 5]
    storage._reorder_archetype_rows(index, order)
    assert_equal(len(storage._archetypes), count)
    assert_equal(storage._archetypes[index].get_mask(), mask)
    for row in range(6):
        assert_equal(
            storage._archetypes[index].get_entity(row), entities[order[row]]
        )
        assert_equal(
            storage._entity_locations[
                entities[order[row]].get_id()
            ].entity_index,
            row,
        )
        assert_true(storage.is_alive(entities[row]))
        assert_equal(storage.get[Int](entities[row]), row)
        assert_equal(storage.get[String](entities[row]), String(row))
        assert_equal(storage.get[Float64](entities[row]), Float64(row + 10))
    assert_equal(storage.get[Int](unrelated), 99)
    # Later structural operations must use the repaired locations.
    storage.set(entities[2], Float64(42))
    storage.remove[String](entities[0])
    storage.remove_entity(entities[4])
    assert_equal(storage.get[Int](entities[2]), 2)
    assert_equal(storage.get[Int](entities[0]), 0)
    assert_false(storage.is_alive(entities[4]))


def test_reorder_rows_invalid_mapping_is_unchanged() raises:
    """Reject malformed mappings and archetype indices before any movement.

    Raises:
        Error: If storage setup, row reordering, or an assertion fails.
    """
    var storage = HostStorage[Int]()
    var first = storage.add_entity(10)
    var second = storage.add_entity(20)
    var index = storage._entity_locations[first.get_id()].archetype_index
    var invalid: List[List[Int]] = [[0], [0, 0], [-1, 0], [1, 2]]
    for order in invalid:
        var rejected = False
        try:
            storage._reorder_archetype_rows(index, order)
        except:
            rejected = True
        assert_true(rejected)
        assert_equal(storage._archetypes[index].get_entity(0), first)
        assert_equal(storage._archetypes[index].get_entity(1), second)
        assert_equal(storage.get[Int](first), 10)
        assert_equal(storage.get[Int](second), 20)
    var rejected = False
    try:
        storage._reorder_archetype_rows(-1, [0, 1])
    except:
        rejected = True
    assert_true(rejected)


def test_reorder_rows_lock_and_empty_archetype() raises:
    """A structural lock rejects movement; empty and identity mappings are valid.

    Raises:
        Error: If storage setup, row reordering, or an assertion fails.
    """
    var storage = HostStorage[Int]()
    storage._reorder_archetype_rows(0, List[Int]())
    var first = storage.add_entity(10)
    var second = storage.add_entity(20)
    var index = storage._entity_locations[first.get_id()].archetype_index
    var lock = storage._lock()
    var rejected = False
    try:
        storage._reorder_archetype_rows(index, [1, 0])
    except err:
        assert_true(err.isa[WorldError]())
        assert_equal(err[WorldError], WorldError.world_is_locked)
        rejected = True
    assert_true(rejected)
    assert_equal(storage._archetypes[index].get_entity(0), first)
    storage._unlock(lock)
    storage._reorder_archetype_rows(index, [1, 0])
    storage._reorder_archetype_rows(index, [0, 1])
    assert_equal(storage._archetypes[index].get_entity(0), second)


def test_reorder_rows_moves_without_copy_or_destruction() raises:
    """Typed reordering preserves nontrivial component ownership.

    Raises:
        Error: If storage setup, row reordering, or an assertion fails.
    """
    var counters = LifecycleCounters()
    var storage = HostStorage[TrackedComponent, Int]()
    var entities = List[Entity]()
    for row in range(3):
        entities.append(storage.add_entity(counters.component(), row))
    var index = storage._entity_locations[entities[0].get_id()].archetype_index
    var copies = counters.copy_counter()
    var moves = counters.move_counter()
    var deletes = counters.del_counter()
    storage._reorder_archetype_rows(index, [2, 0, 1])
    assert_equal(counters.copy_counter(), copies)
    assert_equal(counters.del_counter(), deletes)
    assert_true(counters.move_counter() > moves)
    moves = counters.move_counter()
    storage._reorder_archetype_rows(index, [0, 1, 2])
    assert_equal(counters.move_counter(), moves)
    for row in range(3):
        assert_equal(storage.get[Int](entities[row]), row)
    _ = storage^
    assert_equal(counters.del_counter() - deletes, 3)


@fieldwise_init
struct DescendingSpatialPolicy(SpatialClassifier):
    """Orders integer inputs in descending order without reading tracked data.
    """

    comptime Accessor = EntityAccessor[Filter().read[Int]()]

    def classify(self, entity: Self.Accessor) raises -> UInt64:
        """Computes a descending key for the test's nonnegative rows.

        Args:
            entity: Read-only integer classifier input.

        Raises:
            Error: The classifier interface permits errors; this policy does
                not raise recoverable errors.

        Returns:
            A key reversing the three test rows.
        """
        return UInt64(3 - entity.get[Int]())


def test_spatial_maintenance_preserves_component_lifetimes() raises:
    """Maintenance moves nontrivial columns without copying or destroying them.

    Raises:
        Error: If setup, maintenance, or an assertion fails.
    """
    var counters = LifecycleCounters()
    var world = World[TrackedComponent, Int]()
    var entities = List[Entity]()
    for row in range(3):
        entities.append(world.storage.add_entity(counters.component(), row))
    world.register_spatial_classifier[Filter().read[Int]()](
        DescendingSpatialPolicy()
    )
    var copies = counters.copy_counter()
    var moves = counters.move_counter()
    var deletes = counters.del_counter()
    world.maintain_spatial()
    assert_equal(counters.copy_counter(), copies)
    assert_equal(counters.del_counter(), deletes)
    assert_true(counters.move_counter() > moves)
    moves = counters.move_counter()
    world.maintain_spatial()
    assert_equal(counters.move_counter(), moves)
    # Change two of three identities so this exercises the sparse dirty path.
    world.storage.set(entities[0], 2)
    world.storage.set(entities[2], 0)
    world.maintain_spatial()
    assert_equal(counters.copy_counter(), copies)
    assert_equal(counters.del_counter(), deletes)
    assert_true(counters.move_counter() > moves)
    assert_equal(world.storage.get[Int](entities[0]), 2)
    assert_equal(world.storage.get[Int](entities[1]), 1)
    assert_equal(world.storage.get[Int](entities[2]), 0)
    _ = world^
    assert_equal(counters.del_counter() - deletes, 3)


comptime functions = __functions_in_module()


def main() raises:
    var suite = TestSuite.discover_tests[functions]()
    suite^.run()
