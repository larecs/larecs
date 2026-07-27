from std.testing import *

from larecs.world import World
from larecs.error import ComponentError
from larecs.entity import Entity
from larecs.component import ComponentType
from larecs.resource import ResourceType
from larecs.archetype import MutableEntityAccessor
from larecs.query import QueryInfo

from larecs.test_utils import *


def test_add_entity() raises:
    world = SmallWorld()
    pos = Position(1.0, 2.0)
    vel = Velocity(0.1, 0.2)

    entity = world.add_entity()
    assert_true(entity.get_id() == 1)
    assert_false(entity.is_zero())

    entity = world.add_entity(pos, vel)
    assert_equal(world.get[Position](entity).x, pos.x)
    assert_equal(world.get[Position](entity).y, pos.y)
    assert_equal(world.get[Velocity](entity).dx, vel.dx)
    assert_equal(world.get[Velocity](entity).dy, vel.dy)
    for _ in range(10_000):
        _ = world.add_entity(pos, vel)


def test_add_entities() raises:
    world = SmallWorld()
    pos = Position(1.0, 2.0)
    vel = Velocity(0.1, 0.2)
    i = 0
    for entity in world.add_entities(pos, vel, count=23):
        assert_equal(entity.get[Position]().x, pos.x)
        assert_equal(entity.get[Position]().y, pos.y)
        assert_equal(entity.get[Velocity]().dx, vel.dx)
        assert_equal(entity.get[Velocity]().dy, vel.dy)
        assert_false(entity.has[FlexibleComponent[0]]())
        assert_false(entity.has[FlexibleComponent[1]]())
        assert_false(entity.has[FlexibleComponent[2]]())
        i += 1
    assert_equal(i, 23)

    i = 0
    for entity in world.add_entities(count=25):
        assert_false(entity.has[Velocity]())
        assert_false(entity.has[Position]())
        assert_false(entity.has[FlexibleComponent[0]]())
        assert_false(entity.has[FlexibleComponent[1]]())
        assert_false(entity.has[FlexibleComponent[2]]())
        i += 1
    assert_equal(i, 25)

    i = 0
    for _ in world.add_entities(pos, vel, FlexibleComponent[0](0, 0), count=0):
        i += 1
    assert_equal(i, 0)


def test_add_entities_iterator_length() raises:
    world = SmallWorld()
    pos = Position(1.0, 2.0)
    vel = Velocity(0.1, 0.2)

    iterator = world.add_entities(pos, vel, count=12)
    iter = (iterator^).__iter__()
    for remaining in range(12, 0, -1):
        assert_equal(len(iter), remaining)
        entity = iter.__next__()
        assert_equal(entity.get[Position]().x, pos.x)
        assert_equal(entity.get[Velocity]().dy, vel.dy)

    assert_equal(len(iter), 0)


def test_add_entities_location_after_append_to_archetype() raises:
    """Checks entity locations when batch creation appends to an archetype.

    The second batch starts at a non-zero row in the same archetype. Entity
    handles from that batch must point at their actual archetype rows.
    """
    world = SmallWorld()
    pos = Position(1.0, 2.0)
    _ = world.add_entities(pos, count=3)

    entities = List[Entity]()
    for accessor in world.add_entities(pos, count=2):
        entities.append(accessor.get_entity())

    assert_equal(len(entities), 2)
    expected_archetype_index = world._entities[
        entities[0].get_id()
    ].archetype_index
    assert_equal(
        expected_archetype_index,
        world._entities[entities[1].get_id()].archetype_index,
    )
    assert_equal(world._entities[entities[0].get_id()].entity_index, 3)
    assert_equal(world._entities[entities[1].get_id()].entity_index, 4)
    assert_true(
        world._archetypes[expected_archetype_index].has_components[Position]()
    )
    assert_equal(world.get[Position](entities[0]).x, pos.x)
    assert_equal(world.get[Position](entities[1]).x, pos.x)


def test_world_len() raises:
    world = SmallWorld()
    pos = Position(1.0, 2.0)
    vel = Velocity(0.1, 0.2)
    entity_count = 0
    entity_count += len(world.add_entities(pos, vel, count=12))
    assert_equal(len(world), entity_count)
    entity_count += len(
        world.add_entities(pos, vel, FlexibleComponent[0](0, 0), count=10)
    )
    assert_equal(len(world), entity_count)
    entity_count += len(
        world.add_entities(pos, vel, FlexibleComponent[1](0, 0), count=11)
    )
    assert_equal(len(world), entity_count)


def test_world_remove_entities() raises:
    world = SmallWorld()
    pos = Position(1.0, 2.0)
    vel = Velocity(0.1, 0.2)

    entity_count = 0
    entity_count += len(world.add_entities(pos, vel, count=12))
    entity_count += len(
        world.add_entities(pos, vel, FlexibleComponent[0](0, 0), count=10)
    )
    entity_count += len(
        world.add_entities(pos, vel, FlexibleComponent[1](0, 0), count=11)
    )

    assert_equal(len(world), entity_count)

    _ = world.add_entities(pos, count=13)
    world.remove_entities(world.query[Position, Velocity]().exclusive())

    assert_equal(len(world.query[Position, Velocity]().exclusive()), 0)
    assert_equal(len(world.query[Position, Velocity]()), entity_count - 12)
    assert_equal(len(world), entity_count - 12 + 13)

    world.remove_entities(world.query[Position, Velocity]())
    assert_equal(len(world.query[Position, Velocity]()), 0)
    assert_equal(len(world.query[Position]()), 13)
    assert_equal(len(world), 13)

    entity = world.add_entity(pos, vel)
    assert_equal(entity.get_id(), entity_count)
    assert_equal(entity.get_generation(), 1)
    entity = world.add_entity(pos, vel)
    assert_equal(entity.get_id(), entity_count - 1)
    assert_equal(entity.get_generation(), 1)


def test_entity_get() raises:
    world = SmallWorld()
    pos = Position(1.0, 2.0)
    vel = Velocity(0.1, 0.2)
    entity = world.add_entity(pos, vel)
    assert_equal(world.get[Position](entity).x, pos.x)
    world.get[Position](entity).x = 123
    assert_equal(world.get[Position](entity).x, 123)

    ref entity_pos = world.get[Position](entity)
    entity_pos.x = 456
    assert_equal(world.get[Position](entity).x, 456)


def test_get_archetype_index() raises:
    world = SmallWorld()
    pos = Position(12, 654)
    vel = Velocity(0.1, 0.2)
    _ = world.add_entity(pos)
    _ = world.add_entity(vel)
    _ = world.add_entity(pos, vel)

    def get_index[T: ComponentType](mut world: SmallWorld) raises -> Int:
        return world._get_archetype_index(
            world.component_manager.get_id_arr[T]()
        )

    def get_index[
        T1: ComponentType, T2: ComponentType
    ](mut world: SmallWorld, start: Int = 0) raises -> Int:
        return world._get_archetype_index(
            world.component_manager.get_id_arr[T1, T2](),
            start_node_index=start,
        )

    assert_equal(get_index[Position](world), 1)
    assert_equal(get_index[Velocity](world), 2)
    assert_equal(get_index[Velocity, Position](world), 3)
    assert_equal(get_index[Position, Velocity](world), 3)
    assert_equal(get_index[Velocity, Position](world, 1), 2)
    assert_equal(get_index[Velocity, Position](world, 2), 1)


def test_set_component() raises:
    world = SmallWorld()
    pos = Position(3.0, 4.0)
    entity = world.add_entity(pos)
    pos = Position(2.0, 7.0)
    world.set(entity, pos)
    assert_equal(world.get[Position](entity).x, pos.x)
    assert_equal(world.get[Position](entity).y, pos.y)

    vel = Velocity(0.3, 0.4)
    entity = world.add_entity(pos, vel)
    pos = Position(12, 654)
    vel = Velocity(0.1, 0.2)
    world.set(entity, vel, pos)
    assert_equal(world.get[Position](entity).x, pos.x)
    assert_equal(world.get[Position](entity).y, pos.y)
    assert_equal(world.get[Velocity](entity).dx, vel.dx)
    assert_equal(world.get[Velocity](entity).dy, vel.dy)


def test_remove_entity() raises:
    world = SmallWorld()
    pos = Position(1.0, 2.0)
    vel = Velocity(0.1, 0.2)
    entity = world.add_entity(pos, vel)
    world.remove_entity(entity)

    with assert_raises():
        _ = world.get[Position](entity)
    with assert_raises():
        _ = world.get[Velocity](entity)
    assert_equal(len(world._archetypes[1]._entities), 0)
    assert_equal(len(world._entity_pool), 0)


def test_remove_archetype() raises:
    world = SmallWorld()
    pos = Position(1.0, 2.0)
    vel = Velocity(0.1, 0.2)
    entity1 = world.add_entity(pos, vel)
    entity2 = world.add_entity(pos, vel)
    world.remove_entity(entity1)

    with assert_raises():
        _ = world.get[Position](entity1)
    with assert_raises():
        _ = world.get[Velocity](entity1)
    assert_equal(len(world._archetypes), 2)
    assert_equal(len(world._archetypes[1]._entities), 1)
    assert_equal(len(world._entity_pool), 1)

    world.remove_entity(entity2)
    assert_equal(len(world._archetypes), 2)
    assert_equal(len(world._archetypes[1]._entities), 0)
    assert_equal(len(world._entity_pool), 0)


def test_world_has_component() raises:
    world = SmallWorld()
    pos = Position(1.0, 2.0)
    entity = world.add_entity(pos)
    assert_true(world.has[Position](entity))
    assert_false(world.has[Velocity](entity))


def test_world_add() raises:
    world = SmallWorld()
    pos = Position(1.0, 2.0)
    entity = world.add_entity(pos)
    assert_true(world.has[Position](entity))
    assert_false(world.has[Velocity](entity))
    world.add(entity, Velocity(0.1, 0.2))
    assert_true(world.has[Velocity](entity))
    assert_equal(world.get[Velocity](entity).dx, 0.1)
    assert_equal(world.get[Velocity](entity).dy, 0.2)

    with assert_raises():
        world.add(entity, Velocity(0.3, 0.4))


def test_world_batch_add() raises:
    world = SmallWorld()
    n = 100
    entities = List[Entity]()
    for i in range(n):
        entities.append(world.add_entity(Position(Float64(i), Float64(i + 1))))

    assert_equal(len(world.query[Position]().without[Velocity]()), n)
    assert_equal(len(world.query[Position, Velocity]()), 0)

    for entity in world.add(
        world.query[Position]().without[Velocity](), Velocity(0.1, 0.2)
    ):
        assert_true(entity.has[Velocity]())
        assert_equal(entity.get[Velocity]().dx, 0.1)
        assert_equal(entity.get[Velocity]().dy, 0.2)

    assert_equal(len(world.query[Position]().without[Velocity]()), 0)
    assert_equal(len(world.query[Position, Velocity]()), n)
    for i in range(n):
        entity = entities[i]
        assert_equal(world.get[Position](entity).x, Float64(i))
        assert_equal(world.get[Position](entity).y, Float64(i + 1))
        assert_equal(world.get[Velocity](entity).dx, 0.1)
        assert_equal(world.get[Velocity](entity).dy, 0.2)

    with assert_raises(
        contains=ComponentError.existing_components_on_add_query.msg()
    ):
        _ = world.add(
            world.query[Position]().without[LargerComponent](),
            Velocity(0.3, 0.4),
            FlexibleComponent[0](1.0, 2.0),
        )

    # Check that this raises no error, despite there is no `without_mask`
    _ = world.add(
        world.query[Position](),
        LargerComponent(0.3, 0.4, 0.5),
    )

    assert_equal(len(world.query[Position]().without[Velocity]()), 0)
    assert_equal(len(world.query[Position, Velocity]()), n)


def test_world_remove() raises:
    world = SmallWorld()
    pos = Position(1.0, 2.0)
    vel = Velocity(0.1, 0.2)
    entity = world.add_entity(pos, vel)
    assert_true(world.has[Position](entity))
    assert_true(world.has[Velocity](entity))
    world.remove[Position](entity)
    assert_false(world.has[Position](entity))
    with assert_raises():
        _ = world.get[Position](entity)

    assert_equal(len(world._archetypes), 3)

    with assert_raises():
        world.remove[Position](entity)

    entity = world.add_entity(pos, vel)
    assert_equal(len(world._archetypes), 3)
    world.remove[Position, Velocity](entity)
    assert_equal(len(world._archetypes), 3)
    assert_equal(len(world._archetypes[0]._entities), 1)

    # Test swapping
    entity1 = world.add_entity(pos, vel)
    entity2 = world.add_entity(pos, vel)
    index1 = world._entities[entity1._id].entity_index
    index2 = world._entities[entity2._id].entity_index
    assert_not_equal(index1, index2)
    world.remove[Position](entity1)
    assert_equal(index1, world._entities[entity2._id].entity_index)


def test_world_batch_remove() raises:
    world = SmallWorld()
    n = 100
    _ = world.add_entities(Position(1.0, 2.0), Velocity(0.1, 0.2), count=n)

    assert_equal(len(world.query[Position, Velocity]()), n)
    assert_equal(len(world.query[Position]().without[Velocity]()), 0)

    for entity in world.remove[Velocity](world.query[Position, Velocity]()):
        assert_false(entity.has[Velocity]())
        assert_equal(entity.get[Position]().x, 1.0)
        assert_equal(entity.get[Position]().y, 2.0)

    assert_equal(len(world.query[Position, Velocity]()), 0)
    assert_equal(len(world.query[Position]().without[Velocity]()), n)

    with assert_raises(
        contains=ComponentError.missing_components_on_remove_query.msg()
    ):
        _ = world.remove[Velocity](
            world.query[Position](),
        )


def test_remove_and_add() raises:
    world = SmallWorld()
    pos = Position(1.0, 2.0)
    vel = Velocity(0.1, 0.2)
    entity = world.add_entity(pos)
    assert_true(world.has[Position](entity))
    assert_false(world.has[Velocity](entity))

    _ = world.replace[Velocity]()
    assert_true(world.has[Position](entity))
    assert_false(world.has[Velocity](entity))

    world.replace[Position]().by(vel, entity=entity)
    assert_false(world.has[Position](entity))
    assert_true(world.has[Velocity](entity))
    assert_equal(world.get[Velocity](entity).dx, vel.dx)
    assert_equal(world.get[Velocity](entity).dy, vel.dy)

    with assert_raises():
        world.replace[Position]().by(vel, entity=entity)

    assert_false(world.has[Position](entity))
    assert_true(world.has[Velocity](entity))
    assert_equal(world.get[Velocity](entity).dx, vel.dx)
    assert_equal(world.get[Velocity](entity).dy, vel.dy)


def test_replace_remove_only() raises:
    world = SmallWorld()
    pos = Position(1.0, 2.0)
    vel = Velocity(0.1, 0.2)
    entity = world.add_entity(pos, vel)

    world.replace[Velocity]().by(entity)

    assert_true(world.has[Position](entity))
    assert_false(world.has[Velocity](entity))
    assert_equal(world.get[Position](entity).x, pos.x)
    assert_equal(world.get[Position](entity).y, pos.y)


def test_batch_remove_and_add() raises:
    world = SmallWorld()
    n = 100
    entities = List[Entity]()
    for i in range(n):
        entities.append(
            world.add_entity(
                Position(Float64(i), Float64(i + 1)),
                Velocity(Float64(i) / 10.0, Float64(i) / 5.0),
            )
        )

    assert_equal(len(world.query[Position, Velocity]()), n)
    assert_equal(
        len(world.query[Position, FlexibleComponent[1]]().without[Velocity]()),
        0,
    )

    for entity in world.replace[Velocity]().by(
        FlexibleComponent[1](3.0, 4.0), query=world.query[Position, Velocity]()
    ):
        assert_false(entity.has[Velocity]())
        assert_true(entity.has[Position]())
        assert_true(entity.has[FlexibleComponent[1]]())
        assert_equal(entity.get[FlexibleComponent[1]]().x, 3.0)
        assert_equal(entity.get[FlexibleComponent[1]]().y, 4.0)

    assert_equal(len(world.query[Position, Velocity]()), 0)
    assert_equal(
        len(world.query[Position, FlexibleComponent[1]]().without[Velocity]()),
        n,
    )
    for i in range(n):
        entity = entities[i]
        assert_equal(world.get[Position](entity).x, Float64(i))
        assert_equal(world.get[Position](entity).y, Float64(i + 1))
        assert_equal(world.get[FlexibleComponent[1]](entity).x, 3.0)
        assert_equal(world.get[FlexibleComponent[1]](entity).y, 4.0)

    with assert_raises(
        contains=ComponentError.existing_components_on_add_query.msg()
    ):
        _ = world.replace[Velocity]().by(
            Position(5.0, 6.0), query=world.query[Position]()
        )

    for entity in world.replace[Position]().by(
        Position(42.0, 6.0), query=world.query[Position]()
    ):
        assert_true(entity.has[Position]())
        assert_equal(entity.get[Position]().x, 42.0)
        assert_equal(entity.get[Position]().y, 6.0)


def test_world_batch_add_multiple_source_archetypes() raises:
    world = SmallWorld()
    plain_entities = List[Entity]()
    flex_entities = List[Entity]()

    for i in range(6):
        plain_entities.append(
            world.add_entity(Position(Float64(i), Float64(i + 10)))
        )

    for i in range(4):
        flex_entities.append(
            world.add_entity(
                Position(Float64(100 + i), Float64(200 + i)),
                FlexibleComponent[0](Float64(300 + i), Float32(400 + i)),
            )
        )

    for entity in world.add(
        world.query[Position]().without[Velocity](), Velocity(9.0, 10.0)
    ):
        assert_true(entity.has[Position]())
        assert_true(entity.has[Velocity]())

    first_plain_arch = world._entities[
        plain_entities[0].get_id()
    ].archetype_index
    first_flex_arch = world._entities[flex_entities[0].get_id()].archetype_index

    assert_not_equal(first_plain_arch, first_flex_arch)

    for i in range(len(plain_entities)):
        entity = plain_entities[i]
        loc = world._entities[entity.get_id()]
        assert_equal(loc.archetype_index, first_plain_arch)
        assert_equal(loc.entity_index, i)
        assert_equal(world.get[Position](entity).x, Float64(i))
        assert_equal(world.get[Position](entity).y, Float64(i + 10))
        assert_equal(world.get[Velocity](entity).dx, 9.0)
        assert_equal(world.get[Velocity](entity).dy, 10.0)
        assert_false(world.has[FlexibleComponent[0]](entity))

    for i in range(len(flex_entities)):
        entity = flex_entities[i]
        loc = world._entities[entity.get_id()]
        assert_equal(loc.archetype_index, first_flex_arch)
        assert_equal(loc.entity_index, i)
        assert_equal(world.get[Position](entity).x, Float64(100 + i))
        assert_equal(world.get[Position](entity).y, Float64(200 + i))
        assert_equal(world.get[Velocity](entity).dx, 9.0)
        assert_equal(world.get[Velocity](entity).dy, 10.0)
        assert_equal(
            world.get[FlexibleComponent[0]](entity).x, Float64(300 + i)
        )
        assert_equal(
            world.get[FlexibleComponent[0]](entity).y, Float32(400 + i)
        )


@fieldwise_init
struct Resource1(ResourceType):
    var value: Int


@fieldwise_init
struct Resource2(ResourceType):
    var value: Int


def test_world_resource_access() raises:
    world = World[Position, Velocity]()
    world.resources.add(Resource1(2), Resource2(4))
    assert_equal(world.resources.get[Resource1]().value, 2)
    assert_equal(world.resources.get[Resource2]().value, 4)
    assert_equal(world.resources.has[Resource1](), True)

    world.resources.set(Resource1(10))
    assert_equal(world.resources.get[Resource1]().value, 10)

    world.resources.remove[Resource1]()
    assert_equal(world.resources.has[Resource1](), False)

    world.resources.add(Resource1(30))
    assert_equal(world.resources.get[Resource1]().value, 30)


def test_world_apply() raises:
    world = SmallWorld()
    pos = Position(1.0, 2.0)
    vel = Velocity(0.1, 0.2)

    new_pos = pos.copy()
    new_pos.x += vel.dx
    new_pos.y += vel.dy

    for _ in range(100):
        _ = world.add_entity(pos, vel)

    def operation(accessor: MutableEntityAccessor) raises:
        ref pos2 = accessor.get[Position]()
        ref vel2 = accessor.get[Velocity]()
        pos2.x += vel2.dx
        pos2.y += vel2.dy

    world.apply[unroll_factor=3](world.query[Position, Velocity](), operation)

    for entity in world.query[Position, Velocity]():
        assert_equal(entity.get[Position]().x, new_pos.x)
        assert_equal(entity.get[Position]().y, new_pos.y)


def test_world_lock() raises:
    world = SmallWorld()
    _ = world.add_entity(Position(1.0, 2.0))
    assert_false(world.is_locked())

    with world._locked():
        assert_true(world.is_locked())

    assert_false(world.is_locked())


# def test_world_apply_SIMD() raises:
#     world = SmallWorld()
#     pos = Position(0.0, 2.0)
#     vel = Velocity(0.1, 0.2)

#     comparison = List[Position](capacity=100)

#     for _ in range(100):
#         pos.x += 1
#         _ = world.add_entity(pos, vel)
#         new_pos = pos.copy()
#         new_pos.x += vel.dx
#         new_pos.y += vel.dy
#         comparison.append(new_pos)

#     def operation[simd_width: Int](accessor: MutableEntityAccessor) raises:
#         ref pos2 = accessor.get[Position]()
#         ref vel2 = accessor.get[Velocity]()

#         comptime _load = load2[simd_width]
#         comptime _store = store2[simd_width]

#         x = _load(pos2.x)
#         y = _load(pos2.y)

#         x += _load(vel2.dx)
#         y += _load(vel2.dy)

#         _store(pos2.x, x)
#         _store(pos2.y, y)

#     world.apply[simd_width=4, unroll_factor=3](
#         world.query[Position, Velocity](), operation
#     )

#     i = 0
#     for entity in world.query[Position, Velocity]():
#         new_pos = comparison[i]
#         assert_equal(entity.get[Position]().x, new_pos.x)
#         assert_equal(entity.get[Position]().y, new_pos.y)
#         i += 1


def test_world_copy() raises:
    world = SmallWorld()
    pos = Position(1.0, 2.0)
    vel = Velocity(0.1, 0.2)

    entity = world.add_entity(pos, vel)
    world_copy = world.copy()

    assert_equal(
        world.get[Position](entity).x, world_copy.get[Position](entity).x
    )
    assert_equal(
        world.get[Position](entity).y, world_copy.get[Position](entity).y
    )
    assert_equal(
        world.get[Velocity](entity).dx, world_copy.get[Velocity](entity).dx
    )
    assert_equal(
        world.get[Velocity](entity).dy, world_copy.get[Velocity](entity).dy
    )


comptime functions = __functions_in_module()


def main() raises:
    TestSuite.discover_tests[functions]().run()
