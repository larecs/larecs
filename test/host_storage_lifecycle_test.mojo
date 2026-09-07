"""HostStorage-level tests for lifecycle safety, bounds safety, and typed errors.

These exercise `HostStorage` directly (rather than through `World`) so they
stay decoupled from the higher-level query API. Batch/filter based operations
are driven through `BitMaskFilter` directly for the same reason.
"""

from std.testing import *
from std.memory import alloc, dealloc, Layout, Allocation

from larecs.host_storage import HostStorage
from larecs.entity import Entity
from larecs.bitmask import BitMask
from larecs.filter import BitMaskFilter
from larecs.error import LarecsError, WorldError, EntityError, ComponentError
from larecs.test_utils import *


comptime TrackedComponent = MemTestStruct[
    MutUnsafeAnyOrigin, MutUnsafeAnyOrigin, MutUnsafeAnyOrigin
]


struct LifecycleCounters(Movable):
    """Lifecycle operation counters for non-trivial component tests."""

    var _copy_counter: Allocation[Int]
    """The number of copy initializations."""

    var _move_counter: Allocation[Int]
    """The number of move initializations."""

    var _del_counter: Allocation[Int]
    """The number of destructor calls."""

    def __init__(out self):
        """Initializes copy, move, and delete counters to zero."""
        self._copy_counter = alloc(Layout[Int].single())
        self._move_counter = alloc(Layout[Int].single())
        self._del_counter = alloc(Layout[Int].single())
        self._copy_counter.unsafe_ptr().unsafe_write(0)
        self._move_counter.unsafe_ptr().unsafe_write(0)
        self._del_counter.unsafe_ptr().unsafe_write(0)

    def __deinit__(deinit self):
        """Destroys and frees the allocated lifecycle counters."""
        self._copy_counter.unsafe_ptr().unsafe_deinit_pointee()
        self._move_counter.unsafe_ptr().unsafe_deinit_pointee()
        self._del_counter.unsafe_ptr().unsafe_deinit_pointee()
        dealloc(self._copy_counter^)
        dealloc(self._move_counter^)
        dealloc(self._del_counter^)

    def del_counter(ref self) -> Int:
        """Returns the current delete counter value."""
        return self._del_counter.unsafe_ptr()[]

    def component(ref self) -> TrackedComponent:
        """Creates a tracked component connected to these counters.

        Returns:
            A component whose copy, move, and destructor operations increment
            this counter set.
        """
        return TrackedComponent(
            self._copy_counter.unsafe_ptr()
            .as_unsafe_any_origin()
            .mut_cast[True](),
            self._move_counter.unsafe_ptr()
            .as_unsafe_any_origin()
            .mut_cast[True](),
            self._del_counter.unsafe_ptr()
            .as_unsafe_any_origin()
            .mut_cast[True](),
        )


# ===----------------------------------------------------------------------=== #
# Bounds-safe validity checks
# ===----------------------------------------------------------------------=== #


def test_host_storage_is_alive_bounds_safe() raises:
    """Foreign/out-of-range entities must not crash `is_alive`.

    Regression test: `EntityPool.is_alive` used to index its internal list
    with the entity's raw id without a bounds check, which aborts (rather
    than returning `False`) for an id beyond anything ever handed out.
    """
    var storage = HostStorage[Position]()
    var entity = storage.add_entity(Position(1.0, 2.0))
    assert_true(storage.is_alive(entity))

    # Far beyond anything ever created.
    assert_false(storage.is_alive(Entity(1_000_000, 0)))
    # Negative ids are never valid public entities, but must not crash.
    assert_false(storage.is_alive(Entity(-1, 0)))


def test_host_storage_get_foreign_entity_raises() raises:
    """`get` must raise a typed error instead of crashing on a foreign entity.

    Regression test: `get` used to look up the entity's archetype location
    before checking whether the entity is alive, so a foreign/out-of-range
    entity could hit an out-of-bounds abort before the alive check ever ran.
    """
    var storage = HostStorage[Position]()
    _ = storage.add_entity(Position(1.0, 2.0))

    with assert_raises(contains=EntityError.non_existent_entity.msg()):
        _ = storage.get[Position](Entity(1_000_000, 0))

    with assert_raises(contains=EntityError.non_existent_entity.msg()):
        _ = storage.get[Position](Entity(-1, 0))


def test_host_storage_get_removed_entity_raises() raises:
    """`get` must raise for an entity that was removed (and thus recycled)."""
    var storage = HostStorage[Position]()
    var entity = storage.add_entity(Position(1.0, 2.0))
    storage.remove_entity(entity)

    with assert_raises(contains=EntityError.non_existent_entity.msg()):
        _ = storage.get[Position](entity)


# ===----------------------------------------------------------------------=== #
# Typed, non-crashing input validation
# ===----------------------------------------------------------------------=== #


def test_host_storage_add_entities_negative_count_raises() raises:
    """A negative public batch count must raise, not crash.

    Regression test: `add_entities` used to only `debug_assert` that `count`
    was non-negative, which is compiled out in non-assert builds and would
    otherwise let a negative count reach `List` indexing with a negative
    offset.
    """
    var storage = HostStorage[Position]()

    with assert_raises(contains=WorldError.negative_count.msg()):
        _ = storage.add_entities(Position(1.0, 2.0), count=-1)


def test_host_storage_add_entities_zero_count_ok() raises:
    """A zero count must still succeed and yield an empty iterator."""
    var storage = HostStorage[Position]()

    var count = 0
    for _ in storage.add_entities(Position(1.0, 2.0), count=0):
        count += 1
    assert_equal(count, 0)


# ===----------------------------------------------------------------------=== #
# Missing-component masks must report exactly the missing bits
# ===----------------------------------------------------------------------=== #


def test_host_storage_remove_missing_component_mask() raises:
    """The missing-components error must report exactly the missing bit.

    Regression test: the error's component mask used to be computed via
    XOR of the archetype mask and the removed-components mask, which also
    reports components the entity *does* have (and is not trying to
    remove) whenever they don't overlap with the removed set.
    """
    comptime HS = HostStorage[Position, Velocity]
    var storage = HS()
    var entity = storage.add_entity(Position(1.0, 2.0))

    comptime velocity_id = HS.component_manager.get_id[Velocity]()

    # Only Velocity's bit must be reported: Position is present (id 0) and
    # was never asked to be removed, so it must not appear in the mask.
    with assert_raises(contains="(" + String(velocity_id) + ")"):
        storage.remove[Velocity](entity)


def test_host_storage_remove_batch_missing_component_mask() raises:
    """The batch missing-components error must report exactly the missing bit.
    """
    comptime HS = HostStorage[Position, Velocity]
    var storage = HS()
    _ = storage.add_entities(Position(1.0, 2.0), count=3)

    comptime position_id = HS.component_manager.get_id[Position]()
    comptime velocity_id = HS.component_manager.get_id[Velocity]()

    with assert_raises(contains="(" + String(velocity_id) + ")"):
        _ = storage.remove[Velocity](BitMaskFilter(BitMask(position_id)))


# ===----------------------------------------------------------------------=== #
# Lifecycle safety for non-trivial components through batch/bulk operations
# ===----------------------------------------------------------------------=== #


def test_host_storage_add_entities_non_trivial_component() raises:
    """Verify batch entity creation initializes (not assigns) new rows.

    Regression test: `add_entities` used to fill freshly appended,
    uninitialized rows via `set_component_range` (assignment), which
    destroys whatever "previous" value is at the target address before
    writing the new one. Freshly appended rows never held a real value, so
    this destroyed garbage memory -- observable here as a spurious
    destructor call before anything was ever removed.
    """
    var counters = LifecycleCounters()
    var storage = HostStorage[TrackedComponent]()

    # Named so we control exactly when it is destroyed: `add_entities`
    # only borrows it (to copy into each row), so it must still be alive
    # after the call.
    var proto = counters.component()
    var base_dels = counters.del_counter()

    var count = 0
    for _ in storage.add_entities(proto, count=5):
        count += 1
    assert_equal(count, 5)

    # `proto` is still alive and nothing has been removed yet, so a
    # spurious destructor call here would mean a row's memory was
    # assigned into instead of initialized.
    assert_equal(counters.del_counter(), base_dels)

    _ = storage^
    # Every one of the 5 stored rows must be destroyed exactly once.
    assert_equal(counters.del_counter() - base_dels, count)

    _ = proto^
    assert_equal(counters.del_counter() - base_dels, count + 1)
    # Keep `counters` live until after `proto` is destroyed: it holds
    # unsafe pointers to these counter allocations.
    _ = counters.del_counter()


def test_host_storage_add_migration_non_trivial_component() raises:
    """Verify batch component-add-with-migration initializes new rows.

    Regression test: `_batch_remove_and_add` used to fill the newly added
    component's rows via `set_component_range` (assignment) after migrating
    entities to a new archetype via `extend_from_archetype_unsafe`, which
    never initializes the newly added component's column for the migrated
    rows -- so the assignment destroyed uninitialized memory.
    """
    comptime HS = HostStorage[TrackedComponent, LargerComponent]
    var counters = LifecycleCounters()
    var storage = HS()

    # Give every entity a `LargerComponent` first, so adding
    # `TrackedComponent` below must migrate them to a new archetype.
    # Entities are created one at a time (rather than via `add_entities`)
    # so this setup does not depend on iterator-lock release timing, which
    # is unrelated to what this test targets.
    var created = 0
    for _ in range(4):
        _ = storage.add_entity(LargerComponent(0, 0, 0))
        created += 1
    assert_equal(created, 4)

    comptime larger_id = HS.component_manager.get_id[LargerComponent]()
    var base_dels = counters.del_counter()

    # `add` takes its components by ownership (unlike `add_entities`, which
    # borrows and copies its prototype into every row): the value passed
    # here is moved through two layers of internal forwarding (`add` to
    # `_batch_remove_and_add`) before every migrated row's value is copied
    # from it, which accounts for two extra destructor calls beyond the one
    # stored per migrated row.
    var migrated = 0
    for _ in storage.add[TrackedComponent](
        BitMaskFilter(BitMask(larger_id)), counters.component()
    ):
        migrated += 1
    assert_equal(migrated, 4)

    _ = storage^
    # Every migrated row's value, plus the internal forwarding copies `add`
    # consumed, must be destroyed exactly once -- no more, no less. A
    # spurious extra destructor call here would mean a migrated row's
    # memory was assigned into instead of initialized.
    assert_equal(counters.del_counter() - base_dels, migrated + 2)
    # Keep `counters` live until after `storage` is destroyed: its
    # components hold unsafe pointers to these counter allocations.
    _ = counters.del_counter()


def test_host_storage_remove_entities_non_trivial_component() raises:
    """Verify bulk removal destroys every active initialized value once.

    Regression test: `Archetype.clear` (used by `remove_entities`) used to
    only reset the stored length without destroying the still-initialized
    values, leaking them; a subsequent reuse of the archetype would then
    also assign over that stale, undestroyed memory instead of initializing
    it.
    """
    var counters = LifecycleCounters()
    comptime HS = HostStorage[TrackedComponent]
    var storage = HS()

    # Entities are created one at a time (rather than via `add_entities`)
    # so this setup does not depend on iterator-lock release timing, which
    # is unrelated to what this test targets.
    var count = 0
    for _ in range(3):
        _ = storage.add_entity(counters.component())
        count += 1
    assert_equal(count, 3)

    comptime tracked_id = HS.component_manager.get_id[TrackedComponent]()
    var base_dels = counters.del_counter()

    storage.remove_entities(BitMaskFilter(BitMask(tracked_id)))

    assert_equal(counters.del_counter() - base_dels, count)

    _ = storage^
    # `clear` must not leave destroyed rows for teardown to double-destroy.
    assert_equal(counters.del_counter() - base_dels, count)
    # Keep `counters` live until after `storage` is destroyed: its
    # components hold unsafe pointers to these counter allocations.
    _ = counters.del_counter()


comptime functions = __functions_in_module()


def main() raises:
    var suite = TestSuite.discover_tests[functions]()
    suite^.run()
