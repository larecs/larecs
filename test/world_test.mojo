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
    var world = SmallWorld()
    var pos = Position(1.0, 2.0)
    var vel = Velocity(0.1, 0.2)

    var entity = world.storage.add_entity()
    assert_true(entity.get_id() == 1)
    assert_false(entity.is_zero())

    entity = world.storage.add_entity(pos, vel)
    assert_equal(world.storage.get[Position](entity).x, pos.x)
    assert_equal(world.storage.get[Position](entity).y, pos.y)
    assert_equal(world.storage.get[Velocity](entity).dx, vel.dx)
    assert_equal(world.storage.get[Velocity](entity).dy, vel.dy)
    for _ in range(10_000):
        _ = world.storage.add_entity(pos, vel)


def test_add_entities() raises:
    var world = SmallWorld()
    var pos = Position(1.0, 2.0)
    var vel = Velocity(0.1, 0.2)
    var i = 0
    for entity in world.storage.add_entities(pos, vel, count=23):
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
    for entity in world.storage.add_entities(count=25):
        assert_false(entity.has[Velocity]())
        assert_false(entity.has[Position]())
        assert_false(entity.has[FlexibleComponent[0]]())
        assert_false(entity.has[FlexibleComponent[1]]())
        assert_false(entity.has[FlexibleComponent[2]]())
        i += 1
    assert_equal(i, 25)

    i = 0
    for _ in world.storage.add_entities(
        pos, vel, FlexibleComponent[0](0, 0), count=0
    ):
        i += 1
    assert_equal(i, 0)


def test_add_entities_iterator_length() raises:
    var world = SmallWorld()
    var pos = Position(1.0, 2.0)
    var vel = Velocity(0.1, 0.2)

    var iterator = world.storage.add_entities(pos, vel, count=12)
    var iter = (iterator^).__iter__()
    for remaining in range(12, 0, -1):
        assert_equal(len(iter), remaining)
        var entity = iter.__next__()
        assert_equal(entity.get[Position]().x, pos.x)
        assert_equal(entity.get[Velocity]().dy, vel.dy)

    assert_equal(len(iter), 0)


def test_add_entities_location_after_append_to_archetype() raises:
    """Checks entity locations when batch creation appends to an archetype.

    The second batch starts at a non-zero row in the same archetype. Entity
    handles from that batch must point at their actual archetype rows.
    """
    var world = SmallWorld()
    var pos = Position(1.0, 2.0)
    _ = world.storage.add_entities(pos, count=3)

    var entities = List[Entity]()
    for accessor in world.storage.add_entities(pos, count=2):
        entities.append(accessor.get_entity())

    assert_equal(len(entities), 2)
    var expected_archetype_index = world.storage._entity_locations[
        entities[0].get_id()
    ].archetype_index
    assert_equal(
        expected_archetype_index,
        world.storage._entity_locations[entities[1].get_id()].archetype_index,
    )
    assert_equal(
        world.storage._entity_locations[entities[0].get_id()].entity_index, 3
    )
    assert_equal(
        world.storage._entity_locations[entities[1].get_id()].entity_index, 4
    )
    assert_true(
        world.storage._archetypes[expected_archetype_index].has_components[
            Position
        ]()
    )
    assert_equal(world.storage.get[Position](entities[0]).x, pos.x)
    assert_equal(world.storage.get[Position](entities[1]).x, pos.x)


def test_world_len() raises:
    var world = SmallWorld()
    var pos = Position(1.0, 2.0)
    var vel = Velocity(0.1, 0.2)
    var entity_count = 0
    entity_count += len(world.storage.add_entities(pos, vel, count=12))
    assert_equal(len(world), entity_count)
    entity_count += len(
        world.storage.add_entities(
            pos, vel, FlexibleComponent[0](0, 0), count=10
        )
    )
    assert_equal(len(world), entity_count)
    entity_count += len(
        world.storage.add_entities(
            pos, vel, FlexibleComponent[1](0, 0), count=11
        )
    )
    assert_equal(len(world), entity_count)


def test_world_remove_entities() raises:
    var world = SmallWorld()
    var pos = Position(1.0, 2.0)
    var vel = Velocity(0.1, 0.2)

    var entity_count = 0
    entity_count += len(world.storage.add_entities(pos, vel, count=12))
    entity_count += len(
        world.storage.add_entities(
            pos, vel, FlexibleComponent[0](0, 0), count=10
        )
    )
    entity_count += len(
        world.storage.add_entities(
            pos, vel, FlexibleComponent[1](0, 0), count=11
        )
    )

    assert_equal(len(world), entity_count)

    _ = world.storage.add_entities(pos, count=13)
    world.storage.remove_entities(
        world.storage.query[Position, Velocity]().exclusive()
    )

    assert_equal(len(world.storage.query[Position, Velocity]().exclusive()), 0)
    assert_equal(
        len(world.storage.query[Position, Velocity]()), entity_count - 12
    )
    assert_equal(len(world), entity_count - 12 + 13)

    world.storage.remove_entities(world.storage.query[Position, Velocity]())
    assert_equal(len(world.storage.query[Position, Velocity]()), 0)
    assert_equal(len(world.storage.query[Position]()), 13)
    assert_equal(len(world), 13)

    var entity = world.storage.add_entity(pos, vel)
    assert_equal(entity.get_id(), entity_count)
    assert_equal(entity.get_generation(), 1)
    entity = world.storage.add_entity(pos, vel)
    assert_equal(entity.get_id(), entity_count - 1)
    assert_equal(entity.get_generation(), 1)


def test_entity_get() raises:
    var world = SmallWorld()
    var pos = Position(1.0, 2.0)
    var vel = Velocity(0.1, 0.2)
    var entity = world.storage.add_entity(pos, vel)
    assert_equal(world.storage.get[Position](entity).x, pos.x)
    world.storage.get[Position](entity).x = 123
    assert_equal(world.storage.get[Position](entity).x, 123)

    ref entity_pos = world.storage.get[Position](entity)
    entity_pos.x = 456
    assert_equal(world.storage.get[Position](entity).x, 456)


def test_get_archetype_index() raises:
    var world = SmallWorld()
    var pos = Position(12, 654)
    var vel = Velocity(0.1, 0.2)
    _ = world.storage.add_entity(pos)
    _ = world.storage.add_entity(vel)
    _ = world.storage.add_entity(pos, vel)

    def get_index[T: ComponentType](mut world: SmallWorld) raises -> Int:
        return world.storage._get_archetype_index(
            world.storage.component_manager.get_id_arr[T]()
        )

    def get_index[
        T1: ComponentType, T2: ComponentType
    ](mut world: SmallWorld, start: Int = 0) raises -> Int:
        return world.storage._get_archetype_index(
            world.storage.component_manager.get_id_arr[T1, T2](),
            start_node_index=start,
        )

    assert_equal(get_index[Position](world), 1)
    assert_equal(get_index[Velocity](world), 2)
    assert_equal(get_index[Velocity, Position](world), 3)
    assert_equal(get_index[Position, Velocity](world), 3)
    assert_equal(get_index[Velocity, Position](world, 1), 2)
    assert_equal(get_index[Velocity, Position](world, 2), 1)


def test_set_component() raises:
    var world = SmallWorld()
    var pos = Position(3.0, 4.0)
    var entity = world.storage.add_entity(pos)
    pos = Position(2.0, 7.0)
    world.storage.set(entity, pos)
    assert_equal(world.storage.get[Position](entity).x, pos.x)
    assert_equal(world.storage.get[Position](entity).y, pos.y)

    var vel = Velocity(0.3, 0.4)
    entity = world.storage.add_entity(pos, vel)
    pos = Position(12, 654)
    vel = Velocity(0.1, 0.2)
    world.storage.set(entity, vel, pos)
    assert_equal(world.storage.get[Position](entity).x, pos.x)
    assert_equal(world.storage.get[Position](entity).y, pos.y)
    assert_equal(world.storage.get[Velocity](entity).dx, vel.dx)
    assert_equal(world.storage.get[Velocity](entity).dy, vel.dy)


def test_remove_entity() raises:
    var world = SmallWorld()
    var pos = Position(1.0, 2.0)
    var vel = Velocity(0.1, 0.2)
    var entity = world.storage.add_entity(pos, vel)
    world.storage.remove_entity(entity)

    with assert_raises():
        _ = world.storage.get[Position](entity)
    with assert_raises():
        _ = world.storage.get[Velocity](entity)
    assert_equal(len(world.storage._archetypes[1]._entities), 0)
    assert_equal(len(world.storage._entity_pool), 0)


def test_remove_archetype() raises:
    var world = SmallWorld()
    var pos = Position(1.0, 2.0)
    var vel = Velocity(0.1, 0.2)
    var entity1 = world.storage.add_entity(pos, vel)
    var entity2 = world.storage.add_entity(pos, vel)
    world.storage.remove_entity(entity1)

    with assert_raises():
        _ = world.storage.get[Position](entity1)
    with assert_raises():
        _ = world.storage.get[Velocity](entity1)
    assert_equal(len(world.storage._archetypes), 2)
    assert_equal(len(world.storage._archetypes[1]._entities), 1)
    assert_equal(len(world.storage._entity_pool), 1)

    world.storage.remove_entity(entity2)
    assert_equal(len(world.storage._archetypes), 2)
    assert_equal(len(world.storage._archetypes[1]._entities), 0)
    assert_equal(len(world.storage._entity_pool), 0)


def test_world_has_component() raises:
    var world = SmallWorld()
    var pos = Position(1.0, 2.0)
    var entity = world.storage.add_entity(pos)
    assert_true(world.storage.has[Position](entity))
    assert_false(world.storage.has[Velocity](entity))


def test_world_add() raises:
    var world = SmallWorld()
    var pos = Position(1.0, 2.0)
    var entity = world.storage.add_entity(pos)
    assert_true(world.storage.has[Position](entity))
    assert_false(world.storage.has[Velocity](entity))
    world.storage.add(entity, Velocity(0.1, 0.2))
    assert_true(world.storage.has[Velocity](entity))
    assert_equal(world.storage.get[Velocity](entity).dx, 0.1)
    assert_equal(world.storage.get[Velocity](entity).dy, 0.2)

    with assert_raises():
        world.storage.add(entity, Velocity(0.3, 0.4))


def test_world_batch_add() raises:
    var world = SmallWorld()
    var n = 100
    var entities = List[Entity]()
    for i in range(n):
        entities.append(
            world.storage.add_entity(Position(Float64(i), Float64(i + 1)))
        )

    assert_equal(len(world.storage.query[Position]().without[Velocity]()), n)
    assert_equal(len(world.storage.query[Position, Velocity]()), 0)

    for entity in world.storage.add(
        world.storage.query[Position]().without[Velocity](), Velocity(0.1, 0.2)
    ):
        assert_true(entity.has[Velocity]())
        assert_equal(entity.get[Velocity]().dx, 0.1)
        assert_equal(entity.get[Velocity]().dy, 0.2)

    assert_equal(len(world.storage.query[Position]().without[Velocity]()), 0)
    assert_equal(len(world.storage.query[Position, Velocity]()), n)
    for i in range(n):
        var entity = entities[i]
        assert_equal(world.storage.get[Position](entity).x, Float64(i))
        assert_equal(world.storage.get[Position](entity).y, Float64(i + 1))
        assert_equal(world.storage.get[Velocity](entity).dx, 0.1)
        assert_equal(world.storage.get[Velocity](entity).dy, 0.2)

    with assert_raises(
        contains=ComponentError.existing_components_on_add_query.msg()
    ):
        _ = world.storage.add(
            world.storage.query[Position]().without[LargerComponent](),
            Velocity(0.3, 0.4),
            FlexibleComponent[0](1.0, 2.0),
        )

    # Check that this raises no error, despite there is no `exclude_mask`
    _ = world.storage.add(
        world.storage.query[Position](),
        LargerComponent(0.3, 0.4, 0.5),
    )

    assert_equal(len(world.storage.query[Position]().without[Velocity]()), 0)
    assert_equal(len(world.storage.query[Position, Velocity]()), n)


def test_world_remove() raises:
    var world = SmallWorld()
    var pos = Position(1.0, 2.0)
    var vel = Velocity(0.1, 0.2)
    var entity = world.storage.add_entity(pos, vel)
    assert_true(world.storage.has[Position](entity))
    assert_true(world.storage.has[Velocity](entity))
    world.storage.remove[Position](entity)
    assert_false(world.storage.has[Position](entity))
    with assert_raises():
        _ = world.storage.get[Position](entity)

    assert_equal(len(world.storage._archetypes), 3)

    with assert_raises():
        world.storage.remove[Position](entity)

    entity = world.storage.add_entity(pos, vel)
    assert_equal(len(world.storage._archetypes), 3)
    world.storage.remove[Position, Velocity](entity)
    assert_equal(len(world.storage._archetypes), 3)
    assert_equal(len(world.storage._archetypes[0]._entities), 1)

    # Test swapping
    var entity1 = world.storage.add_entity(pos, vel)
    var entity2 = world.storage.add_entity(pos, vel)
    var index1 = world.storage._entity_locations[entity1._id].entity_index
    var index2 = world.storage._entity_locations[entity2._id].entity_index
    assert_not_equal(index1, index2)
    world.storage.remove[Position](entity1)
    assert_equal(
        index1, world.storage._entity_locations[entity2._id].entity_index
    )


def test_world_batch_remove() raises:
    var world = SmallWorld()
    var n = 100
    _ = world.storage.add_entities(
        Position(1.0, 2.0), Velocity(0.1, 0.2), count=n
    )

    assert_equal(len(world.storage.query[Position, Velocity]()), n)
    assert_equal(len(world.storage.query[Position]().without[Velocity]()), 0)

    for entity in world.storage.remove[Velocity](
        world.storage.query[Position, Velocity]()
    ):
        assert_false(entity.has[Velocity]())
        assert_equal(entity.get[Position]().x, 1.0)
        assert_equal(entity.get[Position]().y, 2.0)

    assert_equal(len(world.storage.query[Position, Velocity]()), 0)
    assert_equal(len(world.storage.query[Position]().without[Velocity]()), n)

    with assert_raises(
        contains=ComponentError.missing_components_on_remove_query.msg()
    ):
        _ = world.storage.remove[Velocity](
            world.storage.query[Position](),
        )


def test_remove_and_add() raises:
    var world = SmallWorld()
    var pos = Position(1.0, 2.0)
    var vel = Velocity(0.1, 0.2)
    var entity = world.storage.add_entity(pos)
    assert_true(world.storage.has[Position](entity))
    assert_false(world.storage.has[Velocity](entity))

    _ = world.storage.replace[Velocity]()
    assert_true(world.storage.has[Position](entity))
    assert_false(world.storage.has[Velocity](entity))

    world.storage.replace[Position]().by(vel, entity=entity)
    assert_false(world.storage.has[Position](entity))
    assert_true(world.storage.has[Velocity](entity))
    assert_equal(world.storage.get[Velocity](entity).dx, vel.dx)
    assert_equal(world.storage.get[Velocity](entity).dy, vel.dy)

    with assert_raises():
        world.storage.replace[Position]().by(vel, entity=entity)

    assert_false(world.storage.has[Position](entity))
    assert_true(world.storage.has[Velocity](entity))
    assert_equal(world.storage.get[Velocity](entity).dx, vel.dx)
    assert_equal(world.storage.get[Velocity](entity).dy, vel.dy)


def test_replace_remove_only() raises:
    var world = SmallWorld()
    var pos = Position(1.0, 2.0)
    var vel = Velocity(0.1, 0.2)
    var entity = world.storage.add_entity(pos, vel)

    world.storage.replace[Velocity]().by(entity)

    assert_true(world.storage.has[Position](entity))
    assert_false(world.storage.has[Velocity](entity))
    assert_equal(world.storage.get[Position](entity).x, pos.x)
    assert_equal(world.storage.get[Position](entity).y, pos.y)


def test_batch_remove_and_add() raises:
    var world = SmallWorld()
    var n = 100
    var entities = List[Entity]()
    for i in range(n):
        entities.append(
            world.storage.add_entity(
                Position(Float64(i), Float64(i + 1)),
                Velocity(Float64(i) / 10.0, Float64(i) / 5.0),
            )
        )

    assert_equal(len(world.storage.query[Position, Velocity]()), n)
    assert_equal(
        len(
            world.storage.query[Position, FlexibleComponent[1]]().without[
                Velocity
            ]()
        ),
        0,
    )

    for entity in world.storage.replace[Velocity]().by(
        FlexibleComponent[1](3.0, 4.0),
        query=world.storage.query[Position, Velocity](),
    ):
        assert_false(entity.has[Velocity]())
        assert_true(entity.has[Position]())
        assert_true(entity.has[FlexibleComponent[1]]())
        assert_equal(entity.get[FlexibleComponent[1]]().x, 3.0)
        assert_equal(entity.get[FlexibleComponent[1]]().y, 4.0)

    assert_equal(len(world.storage.query[Position, Velocity]()), 0)
    assert_equal(
        len(
            world.storage.query[Position, FlexibleComponent[1]]().without[
                Velocity
            ]()
        ),
        n,
    )
    for i in range(n):
        var entity = entities[i]
        assert_equal(world.storage.get[Position](entity).x, Float64(i))
        assert_equal(world.storage.get[Position](entity).y, Float64(i + 1))
        assert_equal(world.storage.get[FlexibleComponent[1]](entity).x, 3.0)
        assert_equal(world.storage.get[FlexibleComponent[1]](entity).y, 4.0)

    with assert_raises(
        contains=ComponentError.existing_components_on_add_query.msg()
    ):
        _ = world.storage.replace[Velocity]().by(
            Position(5.0, 6.0), query=world.storage.query[Position]()
        )

    for entity in world.storage.replace[Position]().by(
        Position(42.0, 6.0), query=world.storage.query[Position]()
    ):
        assert_true(entity.has[Position]())
        assert_equal(entity.get[Position]().x, 42.0)
        assert_equal(entity.get[Position]().y, 6.0)


def test_world_batch_add_multiple_source_archetypes() raises:
    var world = SmallWorld()
    var plain_entities = List[Entity]()
    var flex_entities = List[Entity]()

    for i in range(6):
        plain_entities.append(
            world.storage.add_entity(Position(Float64(i), Float64(i + 10)))
        )

    for i in range(4):
        flex_entities.append(
            world.storage.add_entity(
                Position(Float64(100 + i), Float64(200 + i)),
                FlexibleComponent[0](Float64(300 + i), Float32(400 + i)),
            )
        )

    for entity in world.storage.add(
        world.storage.query[Position]().without[Velocity](), Velocity(9.0, 10.0)
    ):
        assert_true(entity.has[Position]())
        assert_true(entity.has[Velocity]())

    var first_plain_arch = world.storage._entity_locations[
        plain_entities[0].get_id()
    ].archetype_index
    var first_flex_arch = world.storage._entity_locations[
        flex_entities[0].get_id()
    ].archetype_index

    assert_not_equal(first_plain_arch, first_flex_arch)

    for i in range(len(plain_entities)):
        var entity = plain_entities[i]
        var loc = world.storage._entity_locations[entity.get_id()]
        assert_equal(loc.archetype_index, first_plain_arch)
        assert_equal(loc.entity_index, i)
        assert_equal(world.storage.get[Position](entity).x, Float64(i))
        assert_equal(world.storage.get[Position](entity).y, Float64(i + 10))
        assert_equal(world.storage.get[Velocity](entity).dx, 9.0)
        assert_equal(world.storage.get[Velocity](entity).dy, 10.0)
        assert_false(world.storage.has[FlexibleComponent[0]](entity))

    for i in range(len(flex_entities)):
        var entity = flex_entities[i]
        var loc = world.storage._entity_locations[entity.get_id()]
        assert_equal(loc.archetype_index, first_flex_arch)
        assert_equal(loc.entity_index, i)
        assert_equal(world.storage.get[Position](entity).x, Float64(100 + i))
        assert_equal(world.storage.get[Position](entity).y, Float64(200 + i))
        assert_equal(world.storage.get[Velocity](entity).dx, 9.0)
        assert_equal(world.storage.get[Velocity](entity).dy, 10.0)
        assert_equal(
            world.storage.get[FlexibleComponent[0]](entity).x, Float64(300 + i)
        )
        assert_equal(
            world.storage.get[FlexibleComponent[0]](entity).y, Float32(400 + i)
        )


@fieldwise_init
struct Resource1(ResourceType):
    var value: Int


@fieldwise_init
struct Resource2(ResourceType):
    var value: Int


def test_world_resource_access() raises:
    var world = World[Position, Velocity]()
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
    var world = SmallWorld()
    var pos = Position(1.0, 2.0)
    var vel = Velocity(0.1, 0.2)

    var new_pos = pos.copy()
    new_pos.x += vel.dx
    new_pos.y += vel.dy

    for _ in range(100):
        _ = world.storage.add_entity(pos, vel)

    def operation(accessor: MutableEntityAccessor) raises:
        ref pos2 = accessor.get[Position]()
        ref vel2 = accessor.get[Velocity]()
        pos2.x += vel2.dx
        pos2.y += vel2.dy

    world.storage.apply[unroll_factor=3](
        world.storage.query[Position, Velocity](), operation
    )

    for entity in world.storage.query[Position, Velocity]():
        assert_equal(entity.get[Position]().x, new_pos.x)
        assert_equal(entity.get[Position]().y, new_pos.y)


def test_world_lock() raises:
    var world = SmallWorld()
    _ = world.storage.add_entity(Position(1.0, 2.0))
    assert_false(world.storage.is_locked())

    with world.storage._locked():
        assert_true(world.storage.is_locked())

    assert_false(world.storage.is_locked())


# def test_world_apply_SIMD() raises:
#     world = SmallWorld()
#     pos = Position(0.0, 2.0)
#     vel = Velocity(0.1, 0.2)

#     comparison = List[Position](capacity=100)

#     for _ in range(100):
#         pos.x += 1
#         _ = world.storage.add_entity(pos, vel)
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

#     world.storage.apply[simd_width=4, unroll_factor=3](
#         world.storage.query[Position, Velocity](), operation
#     )

#     i = 0
#     for entity in world.storage.query[Position, Velocity]():
#         new_pos = comparison[i]
#         assert_equal(entity.get[Position]().x, new_pos.x)
#         assert_equal(entity.get[Position]().y, new_pos.y)
#         i += 1


def test_world_copy() raises:
    var world = SmallWorld()
    var pos = Position(1.0, 2.0)
    var vel = Velocity(0.1, 0.2)

    var entity = world.storage.add_entity(pos, vel)
    var world_copy = world.copy()

    assert_equal(
        world.storage.get[Position](entity).x,
        world_copy.storage.get[Position](entity).x,
    )
    assert_equal(
        world.storage.get[Position](entity).y,
        world_copy.storage.get[Position](entity).y,
    )
    assert_equal(
        world.storage.get[Velocity](entity).dx,
        world_copy.storage.get[Velocity](entity).dx,
    )
    assert_equal(
        world.storage.get[Velocity](entity).dy,
        world_copy.storage.get[Velocity](entity).dy,
    )


comptime functions = __functions_in_module()


def main() raises:
    TestSuite.discover_tests[functions]().run()
