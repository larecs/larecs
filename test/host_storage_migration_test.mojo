# MOJO_BUILD_ARGS: -g1

"""HostStorage overlap validation and archetype migration tests."""

from std.testing import *

from larecs.host_storage import HostStorage
from larecs import World, SystemContext, Components
from larecs.entity import Entity
from larecs.filter import Filter
from larecs.error import ComponentError
from larecs.test_utils import *

from fixtures.lifecycle import LifecycleCounters, TrackedComponent


def test_host_storage_add_overlap_preserves_rows() raises:
    """Reject partial and full overlap without changing stored rows.

    Raises:
        Error: If overlap validation or a storage invariant fails.
    """
    comptime for partial in range(2):
        var storage = HostStorage[Int, Float64]()
        var entity = storage.add_entity(Int(7))
        var neighbor = storage.add_entity(Int(11))
        var location = storage._entity_locations[entity.get_id()]
        var archetype_count = len(storage._archetypes)

        with assert_raises(
            contains=ComponentError.existing_components_on_add.msg()
        ):
            comptime if partial:
                storage.add(entity, Int(9), Float64(2))
            else:
                storage.add(entity, Int(9))

        assert_equal(len(storage._archetypes), archetype_count)
        assert_equal(len(storage._entity_pool), 2)
        assert_equal(len(storage.query[Filter()]()), 2)
        assert_equal(len(storage.query[Filter().include[Float64]()]()), 0)
        assert_equal(storage.get[Int](entity), 7)
        assert_equal(storage.get[Int](neighbor), 11)
        assert_equal(
            storage._entity_locations[entity.get_id()].archetype_index,
            location.archetype_index,
        )
        assert_equal(
            storage._entity_locations[entity.get_id()].entity_index,
            location.entity_index,
        )

        # A disjoint add and a swap removal must still use the original row.
        storage.add(entity, Float64(2))
        assert_equal(storage.get[Int](entity), 7)
        assert_equal(storage.get[Float64](entity), 2)
        storage.remove_entity(entity)
        assert_equal(storage.get[Int](neighbor), 11)
        storage.remove_entity(neighbor)
        assert_equal(len(storage.query[Filter()]()), 0)


def test_host_storage_replace_overlap_uses_retained_components() raises:
    """Subtract removed types before checking partial or full overlap.

    Raises:
        Error: If replacement validation or stored values are incorrect.
    """
    comptime for partial in range(2):
        var storage = HostStorage[Int, Float64, Bool]()
        var entity = storage.add_entity(Int(7), Float64(2))
        var location = storage._entity_locations[entity.get_id()]
        var archetype_count = len(storage._archetypes)

        with assert_raises(
            contains=ComponentError.existing_components_on_add.msg()
        ):
            comptime if partial:
                storage.replace[Float64]().by(Int(9), Float64(3), entity=entity)
            else:
                storage.replace[Float64]().by(Int(9), entity=entity)

        assert_equal(len(storage._archetypes), archetype_count)
        assert_equal(len(storage._entity_pool), 1)
        assert_equal(len(storage.query[Filter()]()), 1)
        assert_equal(storage.get[Int](entity), 7)
        assert_equal(storage.get[Float64](entity), 2)
        assert_equal(
            storage._entity_locations[entity.get_id()].archetype_index,
            location.archetype_index,
        )
        assert_equal(
            storage._entity_locations[entity.get_id()].entity_index,
            location.entity_index,
        )

        # Re-adding a removed type is legal, including with a new type.
        storage.replace[Int]().by(Int(9), Bool(True), entity=entity)
        assert_equal(storage.get[Int](entity), 9)
        assert_equal(storage.get[Float64](entity), 2)
        assert_true(storage.get[Bool](entity))
        assert_equal(len(storage.query[Filter()]()), 1)
        storage.remove_entity(entity)
        assert_equal(len(storage.query[Filter()]()), 0)


def test_host_storage_rejected_overlap_preserves_lifecycles() raises:
    """Rejected adds and replacements must not touch retained ownership.

    Raises:
        Error: If rejection moves, copies, or destroys a retained component.
    """
    var counters = LifecycleCounters()
    var storage = HostStorage[TrackedComponent, Int, Float64, Bool]()
    var entity = storage.add_entity(counters.component(), Int(7), Bool(True))
    var base_copies = counters.copy_counter()
    var base_moves = counters.move_counter()
    var base_dels = counters.del_counter()

    with assert_raises(
        contains=ComponentError.existing_components_on_add.msg()
    ):
        storage.add(entity, Int(9), Float64(2))
    with assert_raises(
        contains=ComponentError.existing_components_on_add.msg()
    ):
        storage.replace[Bool]().by(Int(9), Float64(2), entity=entity)

    assert_equal(counters.copy_counter(), base_copies)
    assert_equal(counters.move_counter(), base_moves)
    assert_equal(counters.del_counter(), base_dels)
    assert_equal(storage.get[Int](entity), 7)
    assert_true(storage.get[Bool](entity))
    assert_true(storage.has[TrackedComponent](entity))
    storage.remove_entity(entity)
    assert_equal(counters.del_counter() - base_dels, 1)
    assert_equal(len(storage.query[Filter()]()), 0)
    _ = storage^
    assert_equal(counters.del_counter() - base_dels, 1)


def test_host_storage_single_batch_migration_roundtrip() raises:
    """Keep identity and values through the same single and batch transitions.

    Exercise retained, removed, replaced and added sets together, append to an
    occupied destination, replace in place, and return to the original mask.

    Raises:
        Error: If structural operations, locations, or payload checks fail.
    """
    comptime for batch in range(2):
        var storage = HostStorage[Int, String, Float64, Bool]()
        var destination = storage.add_entity(Int(99), String("existing"), True)
        var entities = List[Entity]()
        for i in range(5):
            entities.append(storage.add_entity(i, String(i), Float64(i)))
        comptime if batch:
            var count = 0
            for entity in storage.replace[String, Float64]().by[
                filter=Filter().include[Int, String, Float64]()
            ](String("replacement"), True):
                assert_equal(storage.get[Int](entity), count)
                count += 1
            assert_equal(count, 5)
        else:
            for entity in entities:
                storage.replace[String, Float64]().by(
                    String("replacement"), True, entity=entity
                )
        for i in range(5):
            assert_equal(storage.get[Int](entities[i]), i)
            assert_equal(storage.get[String](entities[i]), "replacement")
            assert_true(storage.has[Bool](entities[i]))
            assert_false(storage.has[Float64](entities[i]))
        assert_equal(storage.get[String](destination), "existing")
        storage.remove_entity(destination)
        comptime if batch:
            _ = storage.replace[String]().by[
                filter=Filter().include[Int, String, Bool]()
            ](String("in place"))
            _ = storage.replace[Bool]().by[
                filter=Filter().include[Int, String, Bool]()
            ](Float64(7))
        else:
            for entity in entities:
                storage.replace[String]().by(String("in place"), entity=entity)
                storage.replace[Bool]().by(Float64(7), entity=entity)
        assert_equal(len(storage.query[Filter()]()), 5)
        for i in range(5):
            var entity = entities[i]
            assert_equal(storage.get[Int](entity), i)
            assert_equal(storage.get[String](entity), "in place")
            assert_equal(storage.get[Float64](entity), 7)
            assert_false(storage.has[Bool](entity))
            storage.remove_entity(entity)
        assert_equal(len(storage.query[Filter()]()), 0)


def test_selection_replacement_uses_migration_lifecycle() raises:
    """Destroy replaced values when exact selections change archetype.

    Raises:
        Error: If selected mutation or a lifecycle assertion fails.
    """
    var old = LifecycleCounters()
    var replacement = LifecycleCounters()
    var world = World[TrackedComponent, Int]()
    var context = SystemContext(world)
    var selection = context.add_entities(old.component(), count=2)
    var baseline = old.del_counter()
    selection.replace[remove=Components[TrackedComponent]()](
        replacement.component(), Int(7)
    )
    assert_equal(old.del_counter() - baseline, 2)
    assert_equal(len(selection), 2)
    selection^.release()
    for row in world.storage.query[Filter().include[Int]()]():
        assert_equal(row.get[Int](), 7)
    _ = context^
    _ = world^
    assert_equal(old.del_counter(), old.copy_counter() + 1)
    assert_equal(replacement.del_counter(), replacement.copy_counter() + 1)


comptime functions = __functions_in_module()


def main() raises:
    var suite = TestSuite.discover_tests[functions]()
    suite^.run()
