# MOJO_BUILD_ARGS: -g1

"""HostStorage replacement lifecycle tests for non-trivial components."""

from std.testing import *

from larecs.host_storage import HostStorage
from larecs.entity import Entity
from larecs.filter import Filter
from larecs.test_utils import *

from fixtures.lifecycle import LifecycleCounters, TrackedComponent


@fieldwise_init
struct RetainedValue[counter_origin: MutOrigin](Copyable, Movable):
    """A tracked component with an owning payload retained by migration.

    Parameters:
        counter_origin: The origin of the lifecycle counter pointers.
    """

    var tracked: MemTestStruct[
        Self.counter_origin, Self.counter_origin, Self.counter_origin
    ]
    var payload: String


comptime RetainedComponent = RetainedValue[MutUnsafeAnyOrigin]


def test_host_storage_replace_migration_and_swap_lifecycle() raises:
    """Destroy replacements once and move retained values through swap removal.

    Raises:
        Error: If storage operations or lifecycle assertions fail.
    """
    for target_index in range(2):
        var old = LifecycleCounters()
        var replacement = LifecycleCounters()
        var retained = LifecycleCounters()
        var storage = HostStorage[
            TrackedComponent, RetainedComponent, Position, Int
        ]()
        var entities = List[Entity]()
        for i in range(2):
            entities.append(
                storage.add_entity(
                    old.component(),
                    RetainedComponent(retained.component(), String(i)),
                    Position(1, 2),
                )
            )
        var base_moves = retained.move_counter()
        var base_copies = retained.copy_counter()
        storage.replace[TrackedComponent, Position]().by(
            replacement.component(), Int(7), entity=entities[target_index]
        )
        assert_equal(old.del_counter(), 1)
        assert_equal(retained.del_counter(), 0)
        assert_equal(retained.copy_counter(), base_copies)
        assert_equal(retained.move_counter() - base_moves, 2 - target_index)
        assert_equal(storage.get[Int](entities[target_index]), 7)
        for i in range(2):
            assert_equal(
                storage.get[RetainedComponent](entities[i]).payload, String(i)
            )
        # The remaining entity must still resolve after the final row swaps in.
        storage.remove_entity(entities[1 - target_index])
        assert_equal(old.del_counter(), 2)
        assert_equal(retained.del_counter(), 1)
        _ = storage^
        assert_equal(old.del_counter(), 2)
        assert_equal(replacement.del_counter(), 1)
        assert_equal(retained.del_counter(), 2)


def test_host_storage_replace_batch_migration_lifecycle() raises:
    """Destroy batch replacements and move retained values into appended rows.

    Raises:
        Error: If storage operations or lifecycle assertions fail.
    """
    var old = LifecycleCounters()
    var replacement = LifecycleCounters()
    var retained = LifecycleCounters()
    var existing = LifecycleCounters()
    var storage = HostStorage[
        TrackedComponent, RetainedComponent, Position, Int
    ]()
    var destination_entity = storage.add_entity(
        existing.component(),
        RetainedComponent(existing.component(), "existing"),
        Int(99),
    )
    for i in range(3):
        _ = storage.add_entity(
            old.component(),
            RetainedComponent(retained.component(), String(i)),
            Position(1, 2),
        )
    var base_moves = retained.move_counter()
    var base_copies = retained.copy_counter()
    var count = 0
    for entity in storage.replace[TrackedComponent, Position]().by[
        filter=Filter().include[TrackedComponent, Position]()
    ](replacement.component(), Int(7)):
        assert_equal(storage.get[Int](entity), 7)
        assert_equal(
            storage.get[RetainedComponent](entity).payload, String(count)
        )
        count += 1
    assert_equal(count, 3)
    assert_equal(old.del_counter(), 3)
    assert_equal(retained.del_counter(), 0)
    assert_equal(retained.copy_counter(), base_copies)
    assert_equal(retained.move_counter() - base_moves, 3)
    assert_equal(storage.get[Int](destination_entity), 99)
    assert_equal(existing.del_counter(), 0)
    _ = storage^
    assert_equal(old.del_counter(), 3)
    assert_equal(retained.del_counter(), 3)
    assert_equal(existing.del_counter(), 2)
    # Batch prototypes and intermediate copies must also be destroyed once.
    assert_equal(replacement.del_counter(), replacement.copy_counter() + 1)


def test_host_storage_replace_batch_same_archetype_lifecycle() raises:
    """Assign batch replacements in place while retaining other live values.

    Raises:
        Error: If storage operations or lifecycle assertions fail.
    """
    var old = LifecycleCounters()
    var replacement = LifecycleCounters()
    var retained = LifecycleCounters()
    var storage = HostStorage[TrackedComponent, RetainedComponent]()
    for i in range(3):
        _ = storage.add_entity(
            old.component(),
            RetainedComponent(retained.component(), String(i)),
        )
    var base_moves = retained.move_counter()
    var base_copies = retained.copy_counter()
    var count = 0
    for entity in storage.replace[TrackedComponent]().by[
        filter=Filter().include[TrackedComponent]()
    ](replacement.component()):
        assert_equal(
            storage.get[RetainedComponent](entity).payload, String(count)
        )
        count += 1
    assert_equal(count, 3)
    assert_equal(old.del_counter(), 3)
    assert_equal(retained.del_counter(), 0)
    assert_equal(retained.move_counter(), base_moves)
    assert_equal(retained.copy_counter(), base_copies)
    _ = storage^
    assert_equal(old.del_counter(), 3)
    assert_equal(retained.del_counter(), 3)
    assert_equal(replacement.del_counter(), replacement.copy_counter() + 1)


def test_host_storage_replace_owning_strings() raises:
    """Exercise owning replacement values in single and batch migration.

    Raises:
        Error: If storage operations or payload assertions fail.
    """
    var storage = HostStorage[String, Int]()
    var old_payload = String("old owning payload ") * 128
    var new_payload = String("new owning payload ") * 128
    for _ in range(32):
        _ = storage.add_entity(old_payload.copy())
    for entity in storage.replace[String]().by[
        filter=Filter().include[String]().exclude[Int]()
    ](new_payload.copy(), Int(7)):
        assert_equal(storage.get[String](entity), new_payload)
    for _ in range(32):
        var entity = storage.add_entity(old_payload.copy())
        storage.replace[String]().by(new_payload.copy(), Int(9), entity=entity)
        assert_equal(storage.get[String](entity), new_payload)
        storage.replace[String]().by(old_payload.copy(), entity=entity)
        assert_equal(storage.get[String](entity), old_payload)


comptime functions = __functions_in_module()


def main() raises:
    var suite = TestSuite.discover_tests[functions]()
    suite^.run()
