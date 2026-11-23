from std.testing import *
from std.random import random_float64


from std.collections import Dict
from larecs.pool import EntityPool, BitPool
from larecs.entity import Entity


def test_entity_pool_constructor() raises:
    _ = EntityPool()


def test_entity_pool() raises:
    var p = EntityPool()

    var expected_all: List[Entity] = [
        Entity(0),
        Entity(1),
        Entity(2),
        Entity(3),
        Entity(4),
        Entity(5),
    ]
    expected_all[0]._generation = UInt32(UInt16.MAX)

    for _ in range(5):
        _ = p.get()

    assert_equal(expected_all, p._entities, "Wrong initial entities")

    with assert_raises():
        p.recycle(p._entities[0])

    var e0 = p._entities[1]
    p.recycle(e0)
    assert_false(p.is_alive(e0), "Dead entity should not be alive")

    var e0_old = e0
    e0 = p.get()
    expected_all[1]._generation += 1
    assert_true(
        p.is_alive(e0), "Recycled entity of new generation should be alive"
    )
    assert_false(
        p.is_alive(e0_old),
        "Recycled entity of old generation should not be alive",
    )

    assert_equal(expected_all, p._entities, "Wrong _entities after get/recycle")

    e0_old = p._entities[1]
    for i in range(5):
        p.recycle(p._entities[i + 1])
        expected_all[i + 1]._generation += 1

    assert_false(
        p.is_alive(e0_old),
        "Recycled entity of old generation should not be alive",
    )

    for _ in range(5):
        _ = p.get()

    assert_false(
        p.is_alive(e0_old),
        "Recycled entity of old generation should not be alive",
    )
    assert_false(p.is_alive(Entity()), "Zero entity should not be alive")


def test_entity_pool_stochastic() raises:
    var p = EntityPool()

    for _ in range(10):
        p.reset()
        assert_equal(0, len(p))
        assert_equal(0, p.available())

        var alive = Dict[Entity, Bool]()
        for _ in range(10):
            var e = p.get()
            alive[e] = True

        for item in alive.items():
            var e, isAlive = item.key, item.value
            assert_equal(
                isAlive,
                p.is_alive(e),
                "Wrong alive state of entity "
                + String(e)
                + " after initialization",
            )
            if random_float64() > 0.75:
                continue

            p.recycle(e)
            alive[e] = False

        for item in alive.items():
            var e, isAlive = item.key, item.value
            assert_equal(
                isAlive,
                p.is_alive(e),
                "Wrong alive state of entity "
                + String(e)
                + " after 1st removal. Entity is "
                + String(p._entities[e.get_id()]),
            )

        for _ in range(10):
            var e = p.get()
            alive[e] = True

        for item in alive.items():
            var e, isAlive = item.key, item.value
            assert_equal(
                isAlive,
                p.is_alive(e),
                "Wrong alive state of entity "
                + String(e)
                + " after 1st recycling. Entity is "
                + String(p._entities[e.get_id()]),
            )

        assert_equal(0, p._available, "No more _entities should be available")

        for item in alive.items():
            var e, isAlive = item.key, item.value
            if not isAlive or random_float64() > 0.75:
                continue

            p.recycle(e)
            alive[e] = False

        for item in alive.items():
            var e, a = item.key, item.value
            assert_equal(
                a,
                p.is_alive(e),
                "Wrong alive state of entity "
                + String(e)
                + " after 2nd removal. Entity is "
                + String(p._entities[e.get_id()]),
            )


def test_entity_pool_reset_invalidates_handles() raises:
    """Keeps every issued handle dead across resets, reuse, and growth.

    Raises:
        Error: If stale handles revive or pool accounting changes.
    """
    var pool = EntityPool()
    var issued = List[Entity]()
    var zero = pool._entities[0]
    # Shrinking and then growing exercises history beyond the active prefix.
    var sizes: List[Int] = [8, 2, 12, 5, 16]
    for size in sizes:
        var prior_count = len(issued)
        for i in range(size):
            var entity = pool.get()
            assert_equal(entity.get_id(), i + 1)
            assert_true(pool.is_alive(entity))
            for j in range(prior_count):
                assert_false(pool.is_alive(issued[j]))
                assert_not_equal(issued[j], entity)
            issued.append(entity)
            # Recycle and reuse some IDs before resetting the mixed pool.
            if i % 3 == 0:
                pool.recycle(entity)
                entity = pool.get()
                assert_false(pool.is_alive(issued[len(issued) - 1]))
                issued.append(entity)
        pool.recycle(issued[len(issued) - 1])
        assert_equal(len(pool), size - 1)
        assert_equal(pool.available(), 1)
        pool.reset()
        assert_equal(len(pool), 0)
        assert_equal(pool.capacity(), 0)
        assert_equal(pool.available(), 0)
        assert_equal(pool._entities[0], zero)
        assert_true(pool.is_alive(zero))
        assert_false(pool.is_alive(Entity()))
        with assert_raises():
            pool.recycle(zero)
        for stale in issued:
            assert_false(pool.is_alive(stale))
        # An empty reset must not discard the history of inactive IDs.
        pool.reset()


def test_entity_pool_reset_reuses_memory_and_recycles() raises:
    """Reuses reserved storage and preserves LIFO recycling after reset.

    Raises:
        Error: If storage is reallocated or recycled IDs/accounting differ.
    """
    var pool = EntityPool()
    for _ in range(32):
        _ = pool.get()
    var address = Int(pool._entities.unsafe_ptr())
    var reserved = pool._entities.capacity()
    pool.reset()
    for i in range(32):
        var entity = pool.get()
        assert_equal(entity.get_id(), i + 1)
        assert_equal(entity.get_generation(), 1)
        assert_equal(len(pool), i + 1)
        assert_equal(pool.capacity(), i + 1)
        assert_equal(pool.available(), 0)
    assert_equal(Int(pool._entities.unsafe_ptr()), address)
    assert_equal(pool._entities.capacity(), reserved)
    var first = pool._entities[1]
    var last = pool._entities[32]
    pool.recycle(first)
    pool.recycle(last)
    assert_equal(pool.available(), 2)
    assert_equal(len(pool), 30)
    var reused_last = pool.get()
    var reused_first = pool.get()
    assert_equal(reused_last.get_id(), last.get_id())
    assert_equal(reused_first.get_id(), first.get_id())
    assert_false(pool.is_alive(first))
    assert_false(pool.is_alive(last))
    assert_true(pool.is_alive(reused_first))
    assert_true(pool.is_alive(reused_last))
    assert_equal(len(pool), 32)
    assert_equal(pool.available(), 0)
    var beyond = pool.get()
    assert_equal(beyond.get_id(), 33)
    assert_equal(beyond.get_generation(), 0)


def test_entity_pool_reset_copy_history() raises:
    """Copies active and retained generations without sharing mutations.

    Raises:
        Error: If copies lose history or resetting one pool mutates another.
    """
    var pool = EntityPool()
    var first = pool.get()
    var second = pool.get()
    pool.recycle(first)
    var mixed = pool.copy()
    pool.reset()
    assert_true(mixed.is_alive(second))
    assert_false(mixed.is_alive(first))
    assert_equal(mixed.available(), 1)
    var reused = mixed.get()
    assert_equal(reused.get_id(), first.get_id())
    assert_equal(reused.get_generation(), 1)
    var empty = pool.copy()
    var fresh = empty.get()
    assert_equal(fresh.get_generation(), 2)
    assert_false(empty.is_alive(first))
    assert_false(pool.is_alive(fresh))
    empty.reset()
    assert_equal(pool.get(), fresh)
    assert_equal(pool.get().get_generation(), 1)
    assert_equal(empty.get().get_generation(), 3)
    assert_false(empty.is_alive(second))
    assert_equal(empty.get().get_generation(), 1)


def test_entity_pool_reset_generation_wrap() raises:
    """Makes the finite UInt32 generation wrap limitation explicit.

    Raises:
        Error: If reset fails to wrap generations or corrupts reserved zero.
    """
    var pool = EntityPool()
    _ = pool.get()
    pool._entities[1]._generation = UInt32.MAX
    var stale = pool._entities[1]
    pool.reset()
    assert_false(pool.is_alive(stale))
    var fresh = pool.get()
    assert_equal(fresh.get_generation(), 0)
    assert_false(pool.is_alive(stale))
    pool.recycle(fresh)
    assert_equal(pool.get().get_generation(), 1)


def test_bit_pool_constructor() raises:
    var p = BitPool()

    assert_equal(p.capacity, 256)
    assert_equal(p._length, 0)
    assert_equal(p._available, 0)


def test_bit_pool_fresh_allocation() raises:
    var p = BitPool()

    for i in range(p.capacity):
        assert_equal(i, p.get())


def test_bit_pool_exhaustion() raises:
    var p = BitPool()

    for _ in range(p.capacity):
        _ = p.get()

    with assert_raises():
        _ = p.get()


def test_bit_pool_recycle_lifo() raises:
    var p = BitPool()

    for _ in range(10):
        _ = p.get()

    for i in range(10):
        p.recycle(i)

    for i in range(9, -1, -1):
        assert_equal(i, p.get())


def test_bit_pool_recycle_full_capacity() raises:
    var p = BitPool()

    for i in range(p.capacity):
        assert_equal(i, p.get())

    for i in range(p.capacity):
        p.recycle(i)

    for i in range(p.capacity - 1, -1, -1):
        assert_equal(i, p.get())

    with assert_raises():
        _ = p.get()


def test_bit_pool_reset() raises:
    var p = BitPool()

    for i in range(32):
        assert_equal(i, p.get())

    for i in range(10):
        p.recycle(i)

    p.reset()

    assert_equal(p._length, 0)
    assert_equal(p._available, 0)

    for i in range(p.capacity):
        assert_equal(i, p.get())

    with assert_raises():
        _ = p.get()


def test_bit_pool_recycle_after_reset() raises:
    var p = BitPool()

    for _ in range(p.capacity):
        _ = p.get()

    p.reset()

    for i in range(10):
        assert_equal(i, p.get())

    for i in range(10):
        p.recycle(i)

    for i in range(9, -1, -1):
        assert_equal(i, p.get())


comptime functions = __functions_in_module()


def main() raises:
    TestSuite.discover_tests[functions]().run()
