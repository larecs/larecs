from larecs.resource import (
    ResourceStorage,
    ResourceType,
    constrain_device_safe_resources,
)
from larecs.test_utils import MemTestStruct
from std.memory import alloc, Layout
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


@fieldwise_init
struct NonTriviallyMovableResource(ResourceType):
    var value: Int

    def __init__(out self, *, deinit move: Self):
        """Moves the resource using a custom move constructor.

        Args:
            move: The resource to consume.
        """
        self.value = move.value


@fieldwise_init
struct OwningResource(ResourceType):
    var values: List[Int]


@fieldwise_init
struct NestedOwningResource(ResourceType):
    var resource: OwningResource


@fieldwise_init
struct PointerResource(ResourceType):
    var value: Pointer[Int, ImmUntrackedOrigin]


@fieldwise_init
struct ArrayResource(ResourceType):
    var values: Array[Float32, 4]


def test_device_resource_representation() raises:
    """Rejects owning and pointer-bearing resources, including nested fields.

    Raises:
        Error: If raw-byte validation accepts an unsafe representation.
    """
    assert_false(constrain_device_safe_resources[OwningResource]())
    assert_false(constrain_device_safe_resources[NestedOwningResource]())
    assert_false(constrain_device_safe_resources[PointerResource]())
    assert_false(constrain_device_safe_resources[ArrayResource]())


def test_gpu_resource_movability() raises:
    """Checks empty, trivial, and mixed resource lists.

    Raises:
        Error: If resource validation accepts or rejects an incorrect list.
    """
    assert_true(constrain_device_safe_resources[]())
    assert_true(constrain_device_safe_resources[Resource1]())
    assert_true(constrain_device_safe_resources[Resource1, Resource2]())
    assert_false(constrain_device_safe_resources[NonTriviallyMovableResource]())
    assert_false(
        constrain_device_safe_resources[
            Resource1, NonTriviallyMovableResource
        ]()
    )
    assert_false(
        constrain_device_safe_resources[
            NonTriviallyMovableResource, Resource1
        ]()
    )


def test_reseource_init() raises:
    var resources = ResourceStorage()
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
    var resources = ResourceStorage()

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
    var resources = ResourceStorage()

    assert_false(resources.has[Resource1]())
    assert_false(resources.has[Resource2]())

    resources.add[Resource1](Resource1(30))
    assert_true(resources.has[Resource1]())

    resources.add[Resource2](Resource2(40))
    assert_true(resources.has[Resource2]())


def test_resources_get() raises:
    var resources = ResourceStorage()
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
    var resources = ResourceStorage()
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


def test_add_distinct_resource_pack() raises:
    """Accepts empty, single, and distinct owning resource packs.

    Raises:
        Error: If insertion or a storage assertion fails.
    """
    var resources = ResourceStorage()
    resources.add()
    assert_equal(len(resources), 0)
    resources.add(Resource3(7))
    resources.add(Int(1), String("owned"), Resource1(2))
    assert_equal(len(resources), 4)
    assert_equal(resources.get[Int](), 1)
    assert_equal(resources.get[String](), "owned")
    assert_equal(resources.get[Resource1]().value, 2)
    assert_equal(resources.get[Resource3]().value, 7)


def test_add_existing_resource_rejects_entire_pack() raises:
    """Rejects existing types before inserting any part of a mixed pack.

    Raises:
        Error: If setup or a storage assertion fails.
    """
    var resources = ResourceStorage()
    resources.add(Int(10), String("unrelated"))
    with assert_raises(contains="Duplicate resource:"):
        resources.add(Resource1(1), Int(20), Resource2(2))
    assert_equal(len(resources), 2)
    assert_equal(resources.get[Int](), 10)
    assert_equal(resources.get[String](), "unrelated")
    assert_false(resources.has[Resource1]())
    assert_false(resources.has[Resource2]())


def test_add_existing_resource_preserves_lifecycles() raises:
    """Destroys rejected owning values once and retains stored owning values.

    Raises:
        Error: If setup or a lifecycle assertion fails.
    """
    var copies = alloc(Layout[Int].single()).into_managed()
    var moves = alloc(Layout[Int].single()).into_managed()
    var deletes = alloc(Layout[Int].single()).into_managed()
    copies.unsafe_ptr().unsafe_write(0)
    moves.unsafe_ptr().unsafe_write(0)
    deletes.unsafe_ptr().unsafe_write(0)
    comptime Tracked = MemTestStruct[
        MutUnsafeAnyOrigin, MutUnsafeAnyOrigin, MutUnsafeAnyOrigin
    ]
    var resources = ResourceStorage()
    resources.add(
        Tracked(
            copies.unsafe_ptr().as_unsafe_any_origin(),
            moves.unsafe_ptr().as_unsafe_any_origin(),
            deletes.unsafe_ptr().as_unsafe_any_origin(),
        ),
        String("retained"),
    )
    assert_equal(deletes.unsafe_ptr()[], 0)
    with assert_raises(contains="Duplicate resource:"):
        resources.add(
            Resource1(1),
            Tracked(
                copies.unsafe_ptr().as_unsafe_any_origin(),
                moves.unsafe_ptr().as_unsafe_any_origin(),
                deletes.unsafe_ptr().as_unsafe_any_origin(),
            ),
        )
    assert_equal(deletes.unsafe_ptr()[], 1)
    assert_equal(copies.unsafe_ptr()[], 0)
    assert_equal(len(resources), 2)
    assert_false(resources.has[Resource1]())
    assert_equal(resources.get[String](), "retained")
    assert_equal(resources.get[Tracked]().del_counter[], 1)
    resources.remove[Tracked]()
    assert_equal(deletes.unsafe_ptr()[], 2)
    _ = resources^
    assert_equal(deletes.unsafe_ptr()[], 2)


comptime functions = __functions_in_module()


def main() raises:
    TestSuite.discover_tests[functions]().run()
