from std.testing import *

from larecs.test_utils import *
from larecs import Entity, Query
from larecs.archetype import Archetype as _Archetype
from larecs.query import _ArchetypeIterator
from larecs.error import WorldError


def test_query_length() raises:
    var world = SmallWorld()

    var c0 = FlexibleComponent[0](1.0, 2.0)
    var c1 = FlexibleComponent[1](3.0, 4.0)
    var c2 = FlexibleComponent[2](5.0, 6.0)
    var c3 = FlexibleComponent[3](7.0, 8.0)

    var n = 50

    for _ in range(n):
        _ = world.storage.add_entity(c0, c1, c2)
        _ = world.storage.add_entity(c0, c1, c3)
        _ = world.storage.add_entity(c0, c2, c3)
        _ = world.storage.add_entity(c1, c2, c3)
        _ = world.storage.add_entity(c0, c1, c2, c3)

    assert_equal(len(world.storage.query[FlexibleComponent[0]]()), 4 * n)
    assert_equal(len(world.storage.query[FlexibleComponent[1]]()), 4 * n)
    assert_equal(len(world.storage.query[FlexibleComponent[2]]()), 4 * n)
    assert_equal(len(world.storage.query[FlexibleComponent[3]]()), 4 * n)

    assert_equal(
        len(world.storage.query[FlexibleComponent[0], FlexibleComponent[1]]()),
        3 * n,
    )
    assert_equal(
        len(world.storage.query[FlexibleComponent[0], FlexibleComponent[2]]()),
        3 * n,
    )
    assert_equal(
        len(world.storage.query[FlexibleComponent[0], FlexibleComponent[3]]()),
        3 * n,
    )
    assert_equal(
        len(world.storage.query[FlexibleComponent[1], FlexibleComponent[2]]()),
        3 * n,
    )
    assert_equal(
        len(world.storage.query[FlexibleComponent[1], FlexibleComponent[3]]()),
        3 * n,
    )
    assert_equal(
        len(world.storage.query[FlexibleComponent[2], FlexibleComponent[3]]()),
        3 * n,
    )

    assert_equal(
        len(
            world.storage.query[
                FlexibleComponent[0], FlexibleComponent[1], FlexibleComponent[2]
            ]()
        ),
        2 * n,
    )
    assert_equal(
        len(
            world.storage.query[
                FlexibleComponent[0], FlexibleComponent[1], FlexibleComponent[3]
            ]()
        ),
        2 * n,
    )
    assert_equal(
        len(
            world.storage.query[
                FlexibleComponent[0], FlexibleComponent[2], FlexibleComponent[3]
            ]()
        ),
        2 * n,
    )
    assert_equal(
        len(
            world.storage.query[
                FlexibleComponent[1], FlexibleComponent[2], FlexibleComponent[3]
            ]()
        ),
        2 * n,
    )

    assert_equal(
        len(
            world.storage.query[
                FlexibleComponent[0],
                FlexibleComponent[1],
                FlexibleComponent[2],
                FlexibleComponent[3],
            ]()
        ),
        n,
    )
    assert_equal(len(world.storage.query()), 5 * n)

    var iterator = world.storage.query[FlexibleComponent[0]]().__iter__()
    var size = len(iterator)
    while iterator:
        _ = iterator.__next__()
        size -= 1
        assert_equal(size, len(iterator))


def test_query_result_ids() raises:
    var world = SmallWorld()

    var c1 = FlexibleComponent[1](3.0, 4.0)
    var c2 = FlexibleComponent[2](5.0, 6.0)

    var n = 50

    var entities = List[Entity]()

    for i in range(n):
        entities.append(
            world.storage.add_entity(
                FlexibleComponent[0](1.0, Float32(i)), c1, c2
            )
        )
    for i in range(n, 2 * n):
        entities.append(
            world.storage.add_entity(FlexibleComponent[0](1.0, Float32(i)), c2)
        )

    var i = 0
    for var entity in world.storage.query[FlexibleComponent[0]]():
        assert_equal(
            entity.get_entity(),
            entities[i],
            "Entity " + String(i) + " is incorrect.",
        )
        entity.set(FlexibleComponent[0](1.0, Float32(i)))
        i += 1

    for i in range(2 * n):
        assert_equal(
            world.storage.get[FlexibleComponent[0]](entities[i]).y, Float32(i)
        )


def test_query_get_set() raises:
    var world = SmallWorld()

    var c0 = FlexibleComponent[0](1.0, 2.0)
    var c1 = FlexibleComponent[1](3.0, 4.0)
    var c2 = FlexibleComponent[2](5.0, 6.0)

    var n = 50

    var entities = List[Entity]()

    for _ in range(n):
        entities.append(world.storage.add_entity(c0, c1, c2))

    var i = 0
    for entity in world.storage.query[FlexibleComponent[0]]():
        entity.get[FlexibleComponent[0]]().y = Float32(i)
        i += 1

    i = 0
    for entity in world.storage.query[FlexibleComponent[0]]():
        assert_equal(entity.get[FlexibleComponent[0]]().y, Float32(i))
        assert_equal(
            world.storage.get[FlexibleComponent[0]](entities[i]).y, Float32(i)
        )
        i += 1


def test_query_component_reference() raises:
    var world = SmallWorld()

    var c0 = FlexibleComponent[0](1.0, 2.0)
    var c1 = FlexibleComponent[1](3.0, 4.0)
    var c2 = FlexibleComponent[2](5.0, 6.0)

    var n = 50

    var entities = List[Entity]()

    for _ in range(n):
        entities.append(world.storage.add_entity(c0, c1, c2))

    var i = 0
    for entity in world.storage.query[FlexibleComponent[0]]():
        ref a = entity.get[FlexibleComponent[0]]()
        a.y = Float32(i)
        i += 1

    i = 0
    for entity in world.storage.query[FlexibleComponent[0]]():
        assert_equal(entity.get[FlexibleComponent[0]]().y, Float32(i))
        assert_equal(
            world.storage.get[FlexibleComponent[0]](entities[i]).y, Float32(i)
        )
        i += 1


def test_query_has_component() raises:
    var world = SmallWorld()

    var c0 = FlexibleComponent[0](1.0, 2.0)
    var c1 = FlexibleComponent[1](3.0, 4.0)
    var c2 = FlexibleComponent[2](5.0, 6.0)

    var n = 50

    var entities = List[Entity]()

    for _ in range(n):
        entities.append(world.storage.add_entity(c0, c1, c2))

    for entity in world.storage.query[FlexibleComponent[0]]():
        assert_true(entity.has[FlexibleComponent[0]]())
        assert_true(entity.has[FlexibleComponent[1]]())
        assert_true(entity.has[FlexibleComponent[2]]())
        assert_false(entity.has[FlexibleComponent[3]]())


def test_query_empty() raises:
    var world = SmallWorld()
    var query = world.storage.query[FlexibleComponent[0]]()
    var cnt = 0
    for entity in query:
        assert_true(entity.has[FlexibleComponent[0]]())
        assert_true(world.storage.is_locked())
        cnt += 1
    assert_equal(cnt, 0)
    assert_false(world.storage.is_locked())


def test_query_iterator_locks_on_creation() raises:
    var world = SmallWorld()

    var c0 = FlexibleComponent[0](1.0, 2.0)
    var c1 = FlexibleComponent[1](3.0, 4.0)
    _ = world.storage.add_entity(c0)

    var iterator = world.storage.query[FlexibleComponent[0]]().__iter__()
    assert_true(world.storage.is_locked())

    with assert_raises():
        _ = world.storage.add_entity(c0, c1)

    var count = 0
    while iterator:
        _ = iterator.__next__()
        count += 1

    assert_equal(count, 1)


def test_query_without() raises:
    var world = SmallWorld()
    var c0 = FlexibleComponent[0](1.0, 2.0)
    var c1 = FlexibleComponent[1](3.0, 4.0)
    var c2 = FlexibleComponent[2](5.0, 6.0)

    var n = 10

    for _ in range(n):
        _ = world.storage.add_entity(c0)
        _ = world.storage.add_entity(c0, c1)
        _ = world.storage.add_entity(c0, c1, c2)
        _ = world.storage.add_entity(c2)

    var query = world.storage.query[FlexibleComponent[0]]().without[
        FlexibleComponent[1]
    ]()
    var query2 = world.storage.query[FlexibleComponent[0]]()

    assert_equal(len(query), n)

    var count = 0
    for entity in query:
        assert_true(entity.has[FlexibleComponent[0]]())
        assert_false(entity.has[FlexibleComponent[1]]())
        assert_true(world.storage.is_locked())
        count += 1
    assert_equal(count, n)
    assert_false(world.storage.is_locked())

    for entity in query2:
        assert_true(entity.has[FlexibleComponent[0]]())
        assert_true(world.storage.is_locked())

    for _ in range(n):
        _ = world.storage.add_entity(c0, c2)

    count = 0
    for entity in query:
        assert_true(entity.has[FlexibleComponent[0]]())
        assert_false(entity.has[FlexibleComponent[1]]())
        assert_true(world.storage.is_locked())
        count += 1
    assert_equal(count, 2 * n)

    assert_false(world.storage.is_locked())


def test_query_exclusive() raises:
    var world = SmallWorld()
    var c0 = FlexibleComponent[0](1.0, 2.0)
    var c1 = FlexibleComponent[1](3.0, 4.0)

    var n = 10

    for _ in range(n):
        _ = world.storage.add_entity(c0)
        _ = world.storage.add_entity(c0, c1)

    var query = world.storage.query[FlexibleComponent[0]]().exclusive()
    assert_equal(len(query), n)

    var count = 0
    for entity in query:
        assert_true(entity.has[FlexibleComponent[0]]())
        assert_false(entity.has[FlexibleComponent[1]]())
        assert_true(world.storage.is_locked())
        count += 1

    assert_equal(count, n)
    assert_false(world.storage.is_locked())


def test_query_without_builder_ownership() raises:
    var world = SmallWorld()
    var c0 = FlexibleComponent[0](1.0, 2.0)
    var c1 = FlexibleComponent[1](3.0, 4.0)
    var c2 = FlexibleComponent[2](5.0, 6.0)

    var n = 10

    for _ in range(n):
        _ = world.storage.add_entity(c0)
        _ = world.storage.add_entity(c0, c1)
        _ = world.storage.add_entity(c0, c2)
        _ = world.storage.add_entity(c0, c1, c2)

    var chained = (
        world.storage.query[FlexibleComponent[0]]()
        .without[FlexibleComponent[1]]()
        .without[FlexibleComponent[2]]()
    )
    assert_equal(len(chained), n)

    var query = world.storage.query[FlexibleComponent[0]]()
    var copied = query.copy().without[FlexibleComponent[1]]()
    assert_equal(len(copied), 2 * n)
    assert_equal(len(query), 4 * n)

    var moved_source = world.storage.query[FlexibleComponent[0]]()
    var moved = moved_source^.without[FlexibleComponent[2]]()
    assert_equal(len(moved), 2 * n)

    var exclusive = (
        world.storage.query[FlexibleComponent[0]]()
        .without[FlexibleComponent[1]]()
        .exclusive()
    )
    assert_equal(len(exclusive), n)


def test_query_lock() raises:
    var world = SmallWorld()

    var c0 = FlexibleComponent[0](1.0, 2.0)
    var c1 = FlexibleComponent[1](3.0, 4.0)
    var c2 = FlexibleComponent[2](5.0, 6.0)

    _ = world.storage.add_entity(c0, c1)
    var entity = world.storage.add_entity(c0, c1)

    var first = True
    for _ in world.storage.query[FlexibleComponent[0]]():
        if not first:
            break
        assert_true(world.storage.is_locked())
        with assert_raises():
            _ = world.storage.add_entity(c0, c1, c2)
        with assert_raises():
            _ = world.storage.add(entity, c2)
        with assert_raises():
            _ = world.storage.remove[FlexibleComponent[0]](entity)

        for _ in world.storage.query[FlexibleComponent[0]]():
            if not first:
                break
            assert_true(world.storage.is_locked())
            with assert_raises():
                _ = world.storage.add_entity(c0, c1, c2)
            with assert_raises():
                _ = world.storage.add(entity, c2)
            with assert_raises():
                _ = world.storage.remove[FlexibleComponent[0]](entity)

    assert_false(world.storage.is_locked())
    _ = world.storage.add_entity(c0, c1, c2)
    _ = world.storage.add(entity, c2)
    _ = world.storage.remove[FlexibleComponent[1]](entity)

    try:
        for _ in world.storage.query[FlexibleComponent[0]]():
            _ = world.storage.add_entity(c0, c1, c2)
    except:
        assert_false(world.storage.is_locked())
        _ = world.storage.add_entity(c0, c1, c2)


def test_query_requires_available_lock() raises:
    var world = SmallWorld()

    var c0 = FlexibleComponent[0](1.0, 2.0)
    _ = world.storage.add_entity(c0)

    var locks = List[Int]()
    for _ in range(world.storage._locks.bit_pool.capacity):
        locks.append(world.storage._lock())

    with assert_raises(contains=WorldError.out_of_locks.msg()):
        for _ in world.storage.query[FlexibleComponent[0]]():
            pass

    for i in range(len(locks)):
        world.storage._unlock(locks[i])

    assert_false(world.storage.is_locked())

    var count = 0
    for _ in world.storage.query[FlexibleComponent[0]]():
        count += 1

    assert_equal(count, 1)


def test_query_archetype_iterator() raises:
    comptime Archetype = _Archetype[FlexibleComponent[0]]

    var a1 = Archetype(0, BitMask(0))
    var a2 = Archetype(0, BitMask(0))
    var a3 = Archetype(2, BitMask(0, 1))
    _ = a1.add_entity(Entity(0, 0))
    _ = a2.add_entity(Entity(0, 0))
    _ = a3.add_entity(Entity(0, 0))
    var archetypes: List[Archetype] = [a1^, a2^, a3^]
    var count = 0

    for _ in _ArchetypeIterator(Pointer(to=archetypes), [0, 1, 2]):
        count += 1

    assert_equal(count, 3)


comptime functions = __functions_in_module()


def main() raises:
    TestSuite.discover_tests[functions]().run()
