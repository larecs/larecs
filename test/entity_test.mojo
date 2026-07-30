from std.testing import *
from larecs.entity import Entity, EntityLocation
from larecs.test_utils import SmallWorld, Position


def test_entity_as_index() raises:
    entity = Entity(1, 0)
    arr: List[Int] = [0, 1, 2]

    val = arr[entity.get_id()]
    assert_equal(val, 1)
    _ = val


def test_zero_entity() raises:
    assert_true(Entity().is_zero())
    assert_false(Entity(1, 0).is_zero())


def test_implicit_constructor() raises:
    world = SmallWorld()
    entity = world.storage.add_entity(Position(1, 0))
    storage = List[Entity]()
    for e in world.storage.query[Position]():
        storage.append(e)

    assert_equal(storage[0], entity)


comptime functions = __functions_in_module()


def main() raises:
    TestSuite.discover_tests[functions]().run()
