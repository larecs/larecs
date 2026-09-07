from std.testing import *
from std.sys.info import size_of
from std.memory import alloc, Layout, Allocation

from larecs.archetype import Archetype as _Archetype
from larecs.bitmask import BitMask
from larecs.component import ComponentManager
from larecs.entity import Entity
from larecs.pool import EntityPool
from larecs.test_utils import *
from larecs._utils import assert_unreachable


comptime Archetype = _Archetype[
    FlexibleComponent[0],
    LargerComponent,
    FlexibleComponent[1],
    FlexibleComponent[2],
    FlexibleComponent[3],
    FlexibleComponent[4],
    FlexibleComponent[5],
    FlexibleComponent[6],
    FlexibleComponent[7],
    FlexibleComponent[9],
    FlexibleComponent[10],
]

comptime mask2 = BitMask(1, 2)
comptime mask3 = BitMask(1, 2, 3)
comptime TrackedComponent = MemTestStruct[
    MutUnsafeAnyOrigin, MutUnsafeAnyOrigin, MutUnsafeAnyOrigin
]
comptime NonTrivialArchetype = _Archetype[TrackedComponent]
comptime tracked_mask = BitMask(0)

comptime MixedArchetype = _Archetype[TrackedComponent, LargerComponent]
comptime larger_only_mask = BitMask(1)
"""Activates only `LargerComponent` (id 1); `TrackedComponent` (id 0) stays inactive."""


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

    def copy_counter(ref self) -> Int:
        """Returns the current copy counter value."""
        return self._copy_counter.unsafe_ptr()[]

    def move_counter(ref self) -> Int:
        """Returns the current move counter value."""
        return self._move_counter.unsafe_ptr()[]

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

    def assert_delta(
        ref self,
        base_copies: Int,
        base_moves: Int,
        base_dels: Int,
        expected_copies: Int,
        expected_moves: Int,
        expected_dels: Int,
    ) raises:
        """Asserts lifecycle counter deltas from a captured baseline.

        Args:
            base_copies: The copy counter baseline.
            base_moves: The move counter baseline.
            base_dels: The destructor counter baseline.
            expected_copies: The expected number of additional copies.
            expected_moves: The expected number of additional moves.
            expected_dels: The expected number of additional destructor calls.

        Raises:
            AssertionError: If any lifecycle delta differs from expectation.
        """
        assert_equal(self.copy_counter() - base_copies, expected_copies)
        assert_equal(self.move_counter() - base_moves, expected_moves)
        assert_equal(self.del_counter() - base_dels, expected_dels)


def init_tracked_component(
    mut archetype: NonTrivialArchetype,
    idx: Int,
    var component: TrackedComponent,
):
    """Move-initializes a tracked component row in an archetype.

    Args:
        archetype: The archetype whose component storage is initialized.
        idx: The initialized entity row.
        component: The component value to move into the uninitialized row.
    """
    try:
        archetype._storage.get_component_ptr[TrackedComponent]().unsafe_offset(
            idx
        ).unsafe_write(component^)
    except:
        assert_unreachable(
            "`NonTrivialArchetype` should have `TrackedComponent`."
        )


def test_archetype_init() raises:
    var archetype = Archetype(4, mask2, capacity=10)

    assert_equal(archetype._storage._capacity, 10)
    assert_equal(len(archetype), 0)
    assert_equal(archetype.get_node_index(), 4)
    assert_equal(archetype._storage.get_component_count(), 2)


def test_archetype_reserve() raises:
    var archetype = Archetype(0, mask2)

    assert_equal(len(archetype), 0)
    assert_equal(archetype._storage.get_component_count(), 2)

    archetype.reserve(50)
    assert_equal(archetype._storage._capacity, 64)
    assert_equal(len(archetype), 0)
    assert_equal(archetype._storage.get_component_count(), 2)

    archetype.reserve(5)
    assert_equal(archetype._storage._capacity, 64)
    assert_equal(len(archetype), 0)
    assert_equal(archetype._storage.get_component_count(), 2)

    archetype.reserve(70)
    assert_equal(archetype._storage._capacity, 128)
    assert_equal(len(archetype), 0)
    assert_equal(archetype._storage.get_component_count(), 2)


def test_archetype_get_entity() raises:
    var archetype = Archetype(0, mask2)

    var entity = Entity(0, 0)
    var idx = archetype.add_entity(entity)
    assert_equal(archetype.get_entity(idx), entity)


def test_archetype_remove() raises:
    var archetype = Archetype(0, mask2)

    var entity1 = Entity(0, 0)
    var entity2 = Entity(1, 0)
    _ = archetype.add_entity(entity1)
    _ = archetype.add_entity(entity2)

    assert_equal(len(archetype), 2)
    assert_equal(archetype._entities[0], entity1)
    assert_equal(archetype._entities[1], entity2)

    var swapped = archetype.remove(0)
    assert_true(swapped)
    assert_equal(len(archetype), 1)
    assert_equal(archetype._entities[0], entity2)

    swapped = archetype.remove(0)
    assert_false(swapped)
    assert_equal(len(archetype), 0)
    assert_equal(len(archetype._entities), 0)


def test_archetype_has_component() raises:
    var archetype = Archetype(0, mask2)

    assert_true(archetype.has_components[Archetype.ComponentTypes[1]]())
    assert_true(archetype.has_components[Archetype.ComponentTypes[2]]())
    assert_false(archetype.has_components[Archetype.ComponentTypes[3]]())


def test_archetype_move() raises:
    var archetype = Archetype(0, mask2)

    var idx = archetype.add_entity(Entity())
    archetype.set_components(
        idx,
        LargerComponent(1.0, 2.0, 3.0),
        FlexibleComponent[1](4.0, 5.0),
    )

    var storage_ptr_large = archetype._storage.get_component_ptr[
        LargerComponent
    ]().unsafe_offset(idx)
    var storage_ptr_flex = archetype._storage.get_component_ptr[
        FlexibleComponent[1]
    ]().unsafe_offset(idx)

    var archetype2 = archetype^

    assert_equal(
        storage_ptr_large,
        archetype2._storage.get_component_ptr[LargerComponent]().unsafe_offset(
            idx
        ),
    )
    assert_equal(
        storage_ptr_flex,
        archetype2._storage.get_component_ptr[
            FlexibleComponent[1]
        ]().unsafe_offset(idx),
    )
    assert_equal(archetype2.get_component[LargerComponent](idx).x, 1.0)
    assert_equal(archetype2.get_component[FlexibleComponent[1]](idx).x, 4.0)


def test_archetype_copy() raises:
    var archetype = Archetype(0, mask2)
    var idx = archetype.add_entity(Entity())
    archetype.set_components(
        idx,
        LargerComponent(1.0, 2.0, 3.0),
        FlexibleComponent[1](4.0, 5.0),
    )

    var archetype2 = archetype.copy()

    assert_not_equal(
        archetype._storage.get_component_ptr[LargerComponent]().unsafe_offset(
            idx
        ),
        archetype2._storage.get_component_ptr[LargerComponent]().unsafe_offset(
            idx
        ),
    )
    assert_not_equal(
        archetype._storage.get_component_ptr[
            FlexibleComponent[1]
        ]().unsafe_offset(idx),
        archetype2._storage.get_component_ptr[
            FlexibleComponent[1]
        ]().unsafe_offset(idx),
    )
    assert_equal(archetype2.get_component[LargerComponent](idx).x, 1.0)
    assert_equal(archetype2.get_component[FlexibleComponent[1]](idx).x, 4.0)


def test_entity_accessor_set_components() raises:
    var archetype = Archetype(0, mask2)
    var entity_idx = archetype.add_entity(Entity(10, 3))
    var entity = archetype.get_row_accessor(entity_idx)

    entity.set(
        LargerComponent(1.0, 2.0, 3.0),
        FlexibleComponent[1](4.0, 5.0),
    )

    assert_equal(entity.get[LargerComponent]().x, 1.0)
    assert_equal(entity.get[LargerComponent]().y, 2.0)
    assert_equal(entity.get[FlexibleComponent[1]]().x, 4.0)
    assert_equal(entity.get[FlexibleComponent[1]]().y, 5.0)


def test_archetype_add() raises:
    var archetype = Archetype(0, mask2)

    var entity = Entity(10, 3)
    var index = archetype.add_entity(entity)

    assert_equal(index, 0)
    assert_equal(len(archetype), 1)
    assert_equal(archetype.get_entity(0), entity)


def test_archetype_extend() raises:
    var archetype = Archetype(0, mask2)
    var entity_pool = EntityPool()

    var start_index = archetype.extend(5, entity_pool)

    assert_equal(start_index, 0)
    assert_equal(len(archetype), 5)

    start_index = archetype.extend(5, entity_pool)

    assert_equal(start_index, 5)
    assert_equal(len(archetype), 10)
    for i in range(10):
        assert_equal(archetype.get_entity(i)._id, i + 1)


def test_archetype_get_mask() raises:
    var archetype = Archetype(0, mask3)

    var entity = Entity(10, 3)
    _ = archetype.add_entity(entity)

    var mask = archetype.get_mask()
    assert_equal(mask, BitMask(1, 2, 3))

    var mask2 = BitMask(1, 2, 3)
    assert_equal(mask, mask2)

    mask2 = BitMask(1, 2, 4)
    assert_not_equal(mask, mask2)

    mask2 = BitMask(1, 2)
    assert_not_equal(mask, mask2)


def test_archetype_reserve_non_trivial_component() raises:
    """Verify reserve moves initialized non-trivial component rows."""
    var counters = LifecycleCounters()
    var archetype = NonTrivialArchetype(0, tracked_mask, capacity=2)

    var idx0 = archetype.add_entity(Entity(0, 0))
    init_tracked_component(archetype, idx0, counters.component())
    var idx1 = archetype.add_entity(Entity(1, 0))
    init_tracked_component(archetype, idx1, counters.component())

    var base_copies = counters.copy_counter()
    var base_moves = counters.move_counter()
    var base_dels = counters.del_counter()

    archetype.reserve(4)

    counters.assert_delta(
        base_copies,
        base_moves,
        base_dels,
        expected_copies=0,
        expected_moves=2,
        expected_dels=0,
    )
    _ = archetype^
    # Keep `counters` live until after the archetype is destroyed: its
    # components hold unsafe pointers to these counter allocations.
    _ = counters.del_counter()


def test_archetype_copy_non_trivial_component() raises:
    """Verify copying an archetype deep-copies initialized component rows."""
    var counters = LifecycleCounters()
    var archetype = NonTrivialArchetype(0, tracked_mask, capacity=4)

    var idx0 = archetype.add_entity(Entity(0, 0))
    init_tracked_component(archetype, idx0, counters.component())
    var idx1 = archetype.add_entity(Entity(1, 0))
    init_tracked_component(archetype, idx1, counters.component())

    var base_copies = counters.copy_counter()
    var base_moves = counters.move_counter()
    var base_dels = counters.del_counter()

    var archetype2 = archetype.copy()

    counters.assert_delta(
        base_copies,
        base_moves,
        base_dels,
        expected_copies=2,
        expected_moves=0,
        expected_dels=0,
    )
    assert_not_equal(
        archetype._storage.get_component_ptr[TrackedComponent](),
        archetype2._storage.get_component_ptr[TrackedComponent](),
    )
    _ = archetype2^
    _ = archetype^
    # Keep `counters` live until after both archetypes are destroyed: their
    # components hold unsafe pointers to these counter allocations.
    _ = counters.del_counter()


def test_archetype_remove_non_trivial_component() raises:
    """Verify swap-remove destroys and moves non-trivial component rows."""
    var counters = LifecycleCounters()
    var archetype = NonTrivialArchetype(0, tracked_mask, capacity=4)

    var idx0 = archetype.add_entity(Entity(0, 0))
    init_tracked_component(archetype, idx0, counters.component())
    var idx1 = archetype.add_entity(Entity(1, 0))
    init_tracked_component(archetype, idx1, counters.component())

    var base_copies = counters.copy_counter()
    var base_moves = counters.move_counter()
    var base_dels = counters.del_counter()

    var swapped = archetype.remove(0)

    assert_true(swapped)
    assert_equal(len(archetype), 1)
    counters.assert_delta(
        base_copies,
        base_moves,
        base_dels,
        expected_copies=0,
        expected_moves=1,
        expected_dels=1,
    )
    _ = archetype^
    # Keep `counters` live until after the archetype is destroyed: its
    # components hold unsafe pointers to these counter allocations.
    _ = counters.del_counter()


def test_archetype_copy_component_from_non_trivial_component() raises:
    """Verify copying over a row destroys destination then copies source."""
    var counters = LifecycleCounters()
    var source = NonTrivialArchetype(0, tracked_mask, capacity=2)
    var destination = NonTrivialArchetype(1, tracked_mask, capacity=2)

    var source_idx = source.add_entity(Entity(0, 0))
    init_tracked_component(source, source_idx, counters.component())
    var destination_idx = destination.add_entity(Entity(1, 0))
    init_tracked_component(destination, destination_idx, counters.component())

    var base_copies = counters.copy_counter()
    var base_moves = counters.move_counter()
    var base_dels = counters.del_counter()

    destination.copy_component_from[TrackedComponent](0, source, 1)

    counters.assert_delta(
        base_copies,
        base_moves,
        base_dels,
        expected_copies=1,
        expected_moves=0,
        expected_dels=1,
    )
    _ = destination^
    _ = source^
    # Keep `counters` live until after both archetypes are destroyed: their
    # components hold unsafe pointers to these counter allocations.
    _ = counters.del_counter()


def test_archetype_unsafe_move_all_from_non_trivial_component() raises:
    """Verify unsafe migration moves shared non-trivial component rows."""
    var counters = LifecycleCounters()
    var source = NonTrivialArchetype(0, tracked_mask, capacity=4)
    var destination = NonTrivialArchetype(1, tracked_mask, capacity=1)

    var idx0 = source.add_entity(Entity(0, 0))
    init_tracked_component(source, idx0, counters.component())
    var idx1 = source.add_entity(Entity(1, 0))
    init_tracked_component(source, idx1, counters.component())

    var base_copies = counters.copy_counter()
    var base_moves = counters.move_counter()
    var base_dels = counters.del_counter()

    var start = destination.unsafe_move_all_from_archetype(Pointer(to=source))

    assert_equal(start, 0)
    assert_equal(len(destination), 2)
    assert_equal(len(source), 0)
    counters.assert_delta(
        base_copies,
        base_moves,
        base_dels,
        expected_copies=0,
        expected_moves=2,
        expected_dels=0,
    )
    _ = destination^
    _ = source^
    # Keep `counters` live until after both archetypes are destroyed: their
    # components hold unsafe pointers to these counter allocations.
    _ = counters.del_counter()


def test_archetype_clear_non_trivial_component() raises:
    """Verify clear destroys active initialized values but retains capacity."""
    var counters = LifecycleCounters()
    var archetype = NonTrivialArchetype(0, tracked_mask, capacity=4)

    var idx0 = archetype.add_entity(Entity(0, 0))
    init_tracked_component(archetype, idx0, counters.component())
    var idx1 = archetype.add_entity(Entity(1, 0))
    init_tracked_component(archetype, idx1, counters.component())

    var base_copies = counters.copy_counter()
    var base_moves = counters.move_counter()
    var base_dels = counters.del_counter()
    var capacity_before_clear = archetype._storage._capacity

    archetype.clear()

    assert_equal(len(archetype), 0)
    assert_equal(len(archetype._entities), 0)
    assert_equal(archetype._storage._capacity, capacity_before_clear)
    counters.assert_delta(
        base_copies,
        base_moves,
        base_dels,
        expected_copies=0,
        expected_moves=0,
        expected_dels=2,
    )

    # The archetype must stay usable after clear: new rows must be
    # initialized rather than assigned over the (already-destroyed) memory
    # of the cleared rows.
    var idx2 = archetype.add_entity(Entity(2, 0))
    # `init_tracked_component` move-initializes the freshly constructed
    # component into the row via `unsafe_write`, which counts as one move.
    init_tracked_component(archetype, idx2, counters.component())
    assert_equal(len(archetype), 1)
    assert_equal(archetype._storage._capacity, capacity_before_clear)

    _ = archetype^
    counters.assert_delta(
        base_copies,
        base_moves,
        base_dels,
        expected_copies=0,
        expected_moves=1,
        expected_dels=3,
    )
    # Keep `counters` live until after the archetype is destroyed: its
    # components hold unsafe pointers to these counter allocations.
    _ = counters.del_counter()


def test_archetype_reserve_inactive_non_trivial_column() raises:
    """Verify reserve does not allocate or touch an inactive non-trivial column.

    Regression test: `_resize_t` unconditionally allocates a buffer, even for
    a `None` input. `reserve` used to call it for every column regardless of
    activation, which turned an inactive column's `_data` from `None` into
    `Some(uninitialized allocation)` -- making the column look initialized to
    code that branches on `column._data` (e.g. `swap_remove_entity`,
    `destroy`), which would then treat uninitialized memory as live values.
    """
    var archetype = MixedArchetype(0, larger_only_mask, capacity=2)

    var idx0 = archetype.add_entity(Entity(0, 0))
    archetype.init_components[LargerComponent](
        idx0, LargerComponent(1.0, 2.0, 3.0)
    )
    var idx1 = archetype.add_entity(Entity(1, 0))
    archetype.init_components[LargerComponent](
        idx1, LargerComponent(4.0, 5.0, 6.0)
    )

    assert_false(Bool(archetype._storage._columns[0]._data))

    archetype.reserve(16)

    assert_false(Bool(archetype._storage._columns[0]._data))
    assert_equal(archetype._storage._capacity, 16)
    assert_equal(archetype.get_component[LargerComponent](idx0).x, 1.0)
    assert_equal(archetype.get_component[LargerComponent](idx1).x, 4.0)

    _ = archetype^


comptime functions = __functions_in_module()


def main() raises:
    var suite = TestSuite.discover_tests[functions]()

    suite^.run()
