from larecs.resource import Resources, ResourceType
from std.testing import *


@fieldwise_init
struct Resource1(ResourceType):
    var value: Int


@fieldwise_init
struct Resource2(ResourceType):
    var value: Int


@fieldwise_init
struct Resource3(ResourceType):
    var value: Int


def test_reseource_init() raises:
    var resources = Resources()
    with assert_raises():
        _ = resources.get[Resource1]()
        _ = resources.get[Resource2]()
        _ = resources.get[Resource3]()

    resources.add(Resource1(2), Resource2(4))
    assert_equal(resources.get[Resource1]().value, 2)
    assert_equal(resources.get[Resource2]().value, 4)
    with assert_raises():
        _ = resources.get[Resource3]()

    resources.set[add_if_not_found=True](
        Resource1(2), Resource2(4), Resource3(6)
    )
    assert_equal(resources.get[Resource1]().value, 2)
    assert_equal(resources.get[Resource2]().value, 4)
    assert_equal(resources.get[Resource3]().value, 6)


def test_resources_add_set() raises:
    var resources = Resources()

    with assert_raises():
        resources.set(Resource1(10))

    resources.add(Resource1(30))

    with assert_raises():
        resources.add(Resource1(30))

    with assert_raises():
        resources.set[add_if_not_found=False](Resource2(40))

    resources.set[add_if_not_found=True](Resource2(40))

    assert_equal(resources.get[Resource1]().value, 30)
    assert_equal(resources.get[Resource2]().value, 40)

    resources.set(Resource1(50), Resource2(60))

    assert_equal(resources.get[Resource1]().value, 50)
    assert_equal(resources.get[Resource2]().value, 60)

    ref res1 = resources.get[Resource1]()
    ref res2 = resources.get[Resource2]()

    assert_equal(res1.value, 50)
    assert_equal(res2.value, 60)

    resources.set[Resource2](Resource2(res1.value))

    assert_equal(resources.get[Resource2]().value, 50)


def test_resource_has() raises:
    var resources = Resources()

    assert_false(resources.has[Resource1]())
    assert_false(resources.has[Resource2]())

    resources.add[Resource1](Resource1(30))
    assert_true(resources.has[Resource1]())

    resources.add[Resource2](Resource2(40))
    assert_true(resources.has[Resource2]())


def test_resources_get() raises:
    var resources = Resources()
    resources.add(Resource1(value=10), Resource2(value=20))

    assert_equal(resources.get[Resource1]().value, 10)
    assert_equal(resources.get[Resource2]().value, 20)

    resources.get[Resource1]() = Resource1(30)
    resources.get[Resource2]().value = 40

    assert_equal(resources.get[Resource1]().value, 30)
    assert_equal(resources.get[Resource2]().value, 40)

    ref resource = resources.get[Resource1]()
    assert_equal(resource.value, 30)

    resource.value = 50
    assert_equal(resources.get[Resource1]().value, 50)

    ref res1 = resources.get[Resource1]()
    ref res2 = resources.get[Resource2]()

    assert_equal(res1.value, 50)
    assert_equal(res2.value, 40)


def test_resource_remove() raises:
    var resources = Resources()
    resources.add(Resource1(10), Resource2(20))
    resources.remove[Resource1]()
    with assert_raises():
        _ = resources.get[Resource1]()

    resources.remove[Resource2]()
    with assert_raises():
        _ = resources.get[Resource2]()

    resources.add[Resource1](Resource1(30))
    resources.add[Resource2](Resource2(40))

    resources.remove[Resource1]()
    assert_false(resources.has[Resource1]())

    resources.remove[Resource2]()
    assert_false(resources.has[Resource2]())


comptime functions = __functions_in_module()


def main() raises:
    TestSuite.discover_tests[functions]().run()
