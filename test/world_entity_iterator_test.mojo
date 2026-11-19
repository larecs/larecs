"""Regression tests for separate traversal and structural-lock ownership."""

from std.testing import (
    assert_equal,
    assert_false,
    assert_true,
    assert_raises,
    TestSuite,
)

from larecs.host_storage import HostStorage
from larecs.iteration import _ArchetypeIterator, _WorldEntityIterator
from larecs.bitmask import BitMask
from larecs.filter import BitMaskFilter, Filter
from larecs.error import WorldError
from larecs.static_optional import StaticOptional


def test_unlocked_iterator_needs_no_lock() raises:
    """Traverses without touching the lock manager, even at lock capacity.

    Raises:
        Error: If setup or an assertion fails.
    """
    var storage = HostStorage[Int]()
    var first = storage.add_entity(10)
    var second = storage.add_entity(20)
    var locks = List[Int]()
    for _ in range(storage._locks.bit_pool.capacity):
        locks.append(storage._lock())

    var iterator = _WorldEntityIterator[origin_of(storage._archetypes), Int](
        Pointer(to=storage._archetypes), BitMaskFilter(BitMask(0))
    )
    assert_equal(len(iterator), 2)
    assert_equal(iterator.__next__().get_entity(), first)
    assert_equal(len(iterator), 1)
    assert_equal(iterator.__next__().get_entity(), second)
    assert_false(iterator)
    with assert_raises():
        _ = iterator.__next__()

    for lock in locks:
        storage._unlock(lock)
    assert_false(storage.is_locked())

    var unlocked = _WorldEntityIterator[origin_of(storage._archetypes), Int](
        storage._get_archetype_iterator(BitMask(0))
    )
    assert_false(storage.is_locked())
    assert_equal(len(unlocked), 2)
    for entity in unlocked^:
        assert_false(storage.is_locked())
        entity.unsafe_get[Int]() += 1
    assert_equal(storage.get[Int](first), 11)
    assert_equal(storage.get[Int](second), 21)


def test_locked_iterator_move_and_exhaustion() raises:
    """Moving transfers one lock; exhaustion retains it until destruction.

    Raises:
        Error: If setup or an assertion fails.
    """
    var storage = HostStorage[Int]()
    _ = storage.add_entity(10)
    var iterator = storage.query[Filter().include[Int]()]().__iter__()
    var locks_before_move = storage._locks.locks.copy()
    var moved = iterator^
    var loop_iterator = moved^.__iter__()
    assert_equal(storage._locks.locks, locks_before_move)
    assert_true(storage.is_locked())
    assert_equal(len(loop_iterator), 1)
    _ = loop_iterator.__next__()
    assert_false(loop_iterator)
    with assert_raises():
        _ = loop_iterator.__next__()
    assert_true(storage.is_locked())
    with assert_raises(contains=WorldError.world_is_locked.msg()):
        _ = storage.add_entity(20)
    assert_equal(len(loop_iterator), 0)
    for _ in loop_iterator^:
        pass
    assert_false(storage.is_locked())
    _ = storage.add_entity(20)


def test_nested_locked_iterators_release_independently() raises:
    """Dropping an inner iterator must not release the outer iterator's lock.

    Raises:
        Error: If setup or an assertion fails.
    """
    var storage = HostStorage[Int]()
    _ = storage.add_entity(10)
    var outer = storage.query[Filter().include[Int]()]().__iter__()
    for _ in storage.query[Filter().include[Int]()]():
        break
    assert_true(storage.is_locked())
    assert_equal(len(outer), 1)
    for _ in outer^:
        break
    assert_false(storage.is_locked())


def test_locked_iterator_copy_acquires_independent_lock() raises:
    """Copies traversal state and owns a distinct lock for each iterator.

    Raises:
        Error: If setup or an assertion fails.
    """
    var storage = HostStorage[Int]()
    var first = storage.add_entity(10)
    var second = storage.add_entity(20)
    var original = storage.query[Filter().include[Int]()]()
    assert_equal(original.__next__().get_entity(), first)

    var copied = original.copy()
    var active_locks = 0
    for i in range(storage._locks.bit_pool.capacity):
        if storage._locks.locks.get(i):
            active_locks += 1
    assert_equal(active_locks, 2)

    assert_equal(original.__next__().get_entity(), second)
    assert_equal(copied.__next__().get_entity(), second)
    for _ in copied^:
        pass

    assert_true(storage.is_locked())
    with assert_raises(contains=WorldError.world_is_locked.msg()):
        _ = storage.add_entity(30)

    for _ in original^:
        pass
    assert_false(storage.is_locked())
    _ = storage.add_entity(30)


def test_unlocked_archetype_iterator_start_indices() raises:
    """Lock-free archetype traversal honors start indices and mutable access.

    Raises:
        Error: If setup or an assertion fails.
    """
    var storage = HostStorage[Int]()
    var first = storage.add_entity(10)
    var second = storage.add_entity(20)
    var archetype_iterator = _ArchetypeIterator[
        origin_of(storage._archetypes), Int
    ](Pointer(to=storage._archetypes), BitMaskFilter(BitMask(0)))
    var indices: List[Int] = [1]
    var starts = StaticOptional[List[Int], True](indices^)
    var iterator = _WorldEntityIterator[
        origin_of(storage._archetypes), Int, has_start_indices=True
    ](archetype_iterator^, starts^)
    assert_false(storage.is_locked())
    assert_equal(len(iterator), 1)
    for entity in iterator^:
        assert_equal(entity.get_entity(), second)
        entity.unsafe_get[Int]() = 30
    assert_false(storage.is_locked())
    assert_equal(storage.get[Int](first), 10)
    assert_equal(storage.get[Int](second), 30)


def test_batch_iterator_is_locked() raises:
    """Batch creation wraps traversal and only visits the newly added rows.

    Raises:
        Error: If setup or an assertion fails.
    """
    var storage = HostStorage[Int]()
    _ = storage.add_entity(10)
    var iterator = storage.add_entities(20, count=3)
    assert_true(storage.is_locked())
    assert_equal(len(iterator), 3)
    var count = 0
    for entity in iterator^:
        assert_true(storage.is_locked())
        assert_equal(entity.unsafe_get[Int](), 20)
        count += 1
    assert_equal(count, 3)
    assert_false(storage.is_locked())


def test_shared_selection_independent_cursors() raises:
    """Copies share indices while preserving positions and owner lifetimes.

    Raises:
        Error: If setup or an assertion fails.
    """
    var storage = HostStorage[Int, Float32]()
    _ = storage.add_entity(10)
    _ = storage.add_entity(20, Float32(1))
    var original = storage._get_archetype_iterator(BitMask(0))
    var copied = original.copy()
    assert_true(
        Pointer(to=original._archetype_indices[])
        == Pointer(to=copied._archetype_indices[])
    )
    assert_equal(len(original.__next__()), 1)
    assert_equal(len(original), 1)
    assert_equal(len(copied), 2)
    var advanced = original.copy()
    for _ in original^:
        break
    assert_equal(len(advanced), 1)
    assert_equal(len(advanced.__next__()), 1)
    assert_false(advanced)
    var exhausted = advanced.copy()
    with assert_raises():
        _ = exhausted.__next__()
    assert_equal(len(copied), 2)
    var count = 0
    for _ in copied^:
        count += 1
    assert_equal(count, 2)


def test_explicit_empty_and_exhausted_ranges_keep_start_ordinals() raises:
    """Empty entries must not shift subsequent per-archetype start indices.

    Raises:
        Error: If setup or an assertion fails.
    """
    var storage = HostStorage[Int, Float32]()
    _ = storage.add_entity(10)
    var expected = storage.add_entity(20)
    var removed = storage.add_entity(Float32(1))
    _ = storage.add_entity(30, Float32(2))
    _ = storage.add_entity(40, Float32(3))
    _ = storage.add_entity(50, Float32(4))
    storage.remove_entity(removed)
    var selection: List[Int] = [0, 1, 2, 1, 3, 0]
    var starts: List[Int] = [0, 1, 0, 2, 1, 0]
    var iterator = _WorldEntityIterator[
        origin_of(storage._archetypes), Int, Float32, has_start_indices=True
    ](
        _ArchetypeIterator[origin_of(storage._archetypes), Int, Float32](
            Pointer(to=storage._archetypes), selection^
        ),
        StaticOptional[List[Int], True](starts^),
    )
    assert_true(iterator)
    assert_equal(len(iterator), 3)
    assert_equal(iterator.__next__().get_entity(), expected)
    var copied = iterator.copy()
    assert_equal(len(copied), 2)
    assert_equal(iterator.__next__().unsafe_get[Int](), 40)
    assert_equal(copied.__next__().unsafe_get[Int](), 40)
    assert_equal(len(iterator), 1)
    assert_equal(iterator.__next__().unsafe_get[Int](), 50)
    assert_false(iterator)
    assert_equal(len(iterator), 0)
    with assert_raises():
        _ = iterator.__next__()
    assert_false(iterator)
    assert_equal(copied.__next__().unsafe_get[Int](), 50)
    assert_false(copied)


def test_queries_after_growth_empty_refill_and_storage_copy() raises:
    """Fresh queries follow list growth and independent copied table contents.

    Raises:
        Error: If setup or an assertion fails.
    """
    var storage = HostStorage[Int, Float32, UInt8, Int16, UInt32, Float64]()
    var first = storage.add_entity(10)
    assert_equal(len(storage.query[Filter().include[Int]()]()), 1)
    # Force growth through 32 new component masks without retaining pointers.
    for combination in range(32):
        var mask = BitMask(0)
        for bit in range(5):
            if combination & (1 << bit):
                mask.set[True](bit + 1)
        _ = storage._get_archetype_index_by_mask(mask^)
    _ = storage.add_entity(20, Float32(1))
    assert_equal(len(storage.query[Filter().include[Int]()]()), 2)
    storage.remove_entity(first)
    assert_equal(len(storage.query[Filter().include[Int]()]()), 1)
    var copied = storage.copy()
    _ = storage.add_entity(30)
    assert_equal(len(storage.query[Filter().include[Int]()]()), 2)
    assert_equal(len(copied.query[Filter().include[Int]()]()), 1)
    copied.remove_entities[Filter().include[Int]()]()
    assert_false(copied.query[Filter().include[Int]()]())
    _ = copied.add_entity(40)
    assert_equal(len(copied.query[Filter().include[Int]()]()), 1)
    assert_equal(len(storage.query[Filter().include[Int]()]()), 2)


def test_copied_public_cursor_survives_source_early_exit() raises:
    """A surviving copy retains its lock and traverses subsequent tables.

    Raises:
        Error: If setup or an assertion fails.
    """
    var storage = HostStorage[Int, Float32]()
    var first = storage.add_entity(10)
    var second = storage.add_entity(20, Float32(1))
    var original = storage.query[Filter().include[Int]()]()
    assert_equal(original.__next__().get_entity(), first)
    var copied = original.copy()
    for _ in original^:
        break
    assert_true(storage.is_locked())
    assert_equal(len(copied), 1)
    assert_equal(copied.__next__().get_entity(), second)
    var exhausted = copied.copy()
    assert_false(exhausted)
    for _ in copied^:
        pass
    assert_true(storage.is_locked())
    for _ in exhausted^:
        pass
    assert_false(storage.is_locked())


def main() raises:
    """Runs the iterator ownership regression tests.

    Raises:
        Error: If any test fails.
    """
    TestSuite.discover_tests[__functions_in_module()]().run()
