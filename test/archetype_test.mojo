from std.testing import *
from std.sys.info import size_of

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
    MutUntrackedOrigin, MutUntrackedOrigin, MutUntrackedOrigin
]
comptime NonTrivialArchetype = _Archetype[TrackedComponent]
comptime tracked_mask = BitMask(0)


struct LifecycleCounters(Movable):
    """Lifecycle operation counters for non-trivial component tests."""

    var copy_counter: UnsafePointer[Int, MutUntrackedOrigin]
    """The number of copy initializations."""

    var move_counter: UnsafePointer[Int, MutUntrackedOrigin]
    """The number of move initializations."""

    var del_counter: UnsafePointer[Int, MutUntrackedOrigin]
    """The number of destructor calls."""

    def __init__(out self):
        """Initializes copy, move, and delete counters to zero."""
        self.copy_counter = alloc[Int](1)
        self.move_counter = alloc[Int](1)
        self.del_counter = alloc[Int](1)
        self.copy_counter.unsafe_write(0)
        self.move_counter.unsafe_write(0)
        self.del_counter.unsafe_write(0)

    def __del__(deinit self):
        """Destroys and frees the allocated lifecycle counters."""
        self.copy_counter.unsafe_deinit_pointee()
        self.move_counter.unsafe_deinit_pointee()
        self.del_counter.unsafe_deinit_pointee()
        self.copy_counter.free()
        self.move_counter.free()
        self.del_counter.free()

    def component(ref self) -> TrackedComponent:
        """Creates a tracked component connected to these counters.

        Returns:
            A component whose copy, move, and destructor operations increment
            this counter set.
        """
        return TrackedComponent(
            self.copy_counter, self.move_counter, self.del_counter
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
        assert_equal(self.copy_counter[] - base_copies, expected_copies)
        assert_equal(self.move_counter[] - base_moves, expected_moves)
        assert_equal(self.del_counter[] - base_dels, expected_dels)


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
        (
            archetype._storage.get_component_ptr[TrackedComponent]() + idx
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
    idx = archetype.add_entity(entity)
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

    idx = archetype.add_entity(Entity())
    archetype.set_components(
        idx,
        LargerComponent(1.0, 2.0, 3.0),
        FlexibleComponent[1](4.0, 5.0),
    )

    storage_ptr_large = (
        archetype._storage.get_component_ptr[LargerComponent]() + idx
    )
    storage_ptr_flex = (
        archetype._storage.get_component_ptr[FlexibleComponent[1]]() + idx
    )

    var archetype2 = archetype^

    assert_equal(
        storage_ptr_large,
        archetype2._storage.get_component_ptr[LargerComponent]() + idx,
    )
    assert_equal(
        storage_ptr_flex,
        archetype2._storage.get_component_ptr[FlexibleComponent[1]]() + idx,
    )
    assert_equal(archetype2.get_component[LargerComponent](idx).x, 1.0)
    assert_equal(archetype2.get_component[FlexibleComponent[1]](idx).x, 4.0)


def test_archetype_copy() raises:
    var archetype = Archetype(0, mask2)
    idx = archetype.add_entity(Entity())
    archetype.set_components(
        idx,
        LargerComponent(1.0, 2.0, 3.0),
        FlexibleComponent[1](4.0, 5.0),
    )

    var archetype2 = archetype.copy()

    assert_not_equal(
        archetype._storage.get_component_ptr[LargerComponent]() + idx,
        archetype2._storage.get_component_ptr[LargerComponent]() + idx,
    )
    assert_not_equal(
        archetype._storage.get_component_ptr[FlexibleComponent[1]]() + idx,
        archetype2._storage.get_component_ptr[FlexibleComponent[1]]() + idx,
    )
    assert_equal(archetype2.get_component[LargerComponent](idx).x, 1.0)
    assert_equal(archetype2.get_component[FlexibleComponent[1]](idx).x, 4.0)


def test_entity_accessor_set_components() raises:
    var archetype = Archetype(0, mask2)
    entity_idx = archetype.add_entity(Entity(10, 3))
    entity = archetype.get_entity_accessor(entity_idx)

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

    var base_copies = counters.copy_counter[]
    var base_moves = counters.move_counter[]
    var base_dels = counters.del_counter[]

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
    _ = counters.del_counter[]


def test_archetype_copy_non_trivial_component() raises:
    """Verify copying an archetype deep-copies initialized component rows."""
    var counters = LifecycleCounters()
    var archetype = NonTrivialArchetype(0, tracked_mask, capacity=4)

    var idx0 = archetype.add_entity(Entity(0, 0))
    init_tracked_component(archetype, idx0, counters.component())
    var idx1 = archetype.add_entity(Entity(1, 0))
    init_tracked_component(archetype, idx1, counters.component())

    var base_copies = counters.copy_counter[]
    var base_moves = counters.move_counter[]
    var base_dels = counters.del_counter[]

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
    _ = counters.del_counter[]


def test_archetype_remove_non_trivial_component() raises:
    """Verify swap-remove destroys and moves non-trivial component rows."""
    var counters = LifecycleCounters()
    var archetype = NonTrivialArchetype(0, tracked_mask, capacity=4)

    var idx0 = archetype.add_entity(Entity(0, 0))
    init_tracked_component(archetype, idx0, counters.component())
    var idx1 = archetype.add_entity(Entity(1, 0))
    init_tracked_component(archetype, idx1, counters.component())

    var base_copies = counters.copy_counter[]
    var base_moves = counters.move_counter[]
    var base_dels = counters.del_counter[]

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
    _ = counters.del_counter[]


def test_archetype_copy_component_from_non_trivial_component() raises:
    """Verify copying over a row destroys destination then copies source."""
    var counters = LifecycleCounters()
    var source = NonTrivialArchetype(0, tracked_mask, capacity=2)
    var destination = NonTrivialArchetype(1, tracked_mask, capacity=2)

    var source_idx = source.add_entity(Entity(0, 0))
    init_tracked_component(source, source_idx, counters.component())
    var destination_idx = destination.add_entity(Entity(1, 0))
    init_tracked_component(destination, destination_idx, counters.component())

    var base_copies = counters.copy_counter[]
    var base_moves = counters.move_counter[]
    var base_dels = counters.del_counter[]

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
    _ = counters.del_counter[]


def test_archetype_extend_from_archetype_unsafe_non_trivial_component() raises:
    """Verify unsafe extension copies shared non-trivial component rows."""
    var counters = LifecycleCounters()
    var source = NonTrivialArchetype(0, tracked_mask, capacity=4)
    var destination = NonTrivialArchetype(1, tracked_mask, capacity=1)

    var idx0 = source.add_entity(Entity(0, 0))
    init_tracked_component(source, idx0, counters.component())
    var idx1 = source.add_entity(Entity(1, 0))
    init_tracked_component(source, idx1, counters.component())

    var base_copies = counters.copy_counter[]
    var base_moves = counters.move_counter[]
    var base_dels = counters.del_counter[]

    var start = destination.extend_from_archetype_unsafe(
        UnsafePointer(to=source), 2
    )

    assert_equal(start, 0)
    assert_equal(len(destination), 2)
    counters.assert_delta(
        base_copies,
        base_moves,
        base_dels,
        expected_copies=2,
        expected_moves=0,
        expected_dels=0,
    )
    _ = destination^
    _ = source^
    _ = counters.del_counter[]


comptime functions = __functions_in_module()


def main() raises:
    suite = TestSuite.discover_tests[functions]()

    suite^.run()
