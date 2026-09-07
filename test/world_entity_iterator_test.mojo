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
        entity.get[Int]() += 1
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
        entity.get[Int]() = 30
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
        assert_equal(entity.get[Int](), 20)
        count += 1
    assert_equal(count, 3)
    assert_false(storage.is_locked())


def main() raises:
    """Runs the iterator ownership regression tests.

    Raises:
        Error: If any test fails.
    """
    TestSuite.discover_tests[__functions_in_module()]().run()
