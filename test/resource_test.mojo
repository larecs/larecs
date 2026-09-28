from larecs.resource import (
    ResourceStorage,
    ResourceType,
    constrain_gpu_safe_resources,
    Int32Dict,
    StringDict,
    Int32DictView,
    StringDictView,
    ResourceEncoder,
    Int32DictResource,
    StringDictResource,
)
from std.testing import *
from larecs import World, SystemContext, KernelContext, Filter, Resources


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


def test_gpu_resource_movability() raises:
    """Checks empty, trivial, and mixed resource lists.

    Raises:
        Error: If resource validation accepts or rejects an incorrect list.
    """
    assert_true(constrain_gpu_safe_resources[]())
    assert_true(constrain_gpu_safe_resources[Resource1]())
    assert_true(constrain_gpu_safe_resources[Resource1, Resource2]())
    assert_false(constrain_gpu_safe_resources[Int32Dict]())
    assert_true(constrain_gpu_safe_resources[Int32DictResource]())
    assert_false(constrain_gpu_safe_resources[StringDict]())
    assert_true(constrain_gpu_safe_resources[StringDictResource]())
    assert_false(constrain_gpu_safe_resources[Dict[Int32, Int64]]())
    assert_false(constrain_gpu_safe_resources[NonTriviallyMovableResource]())
    assert_false(
        constrain_gpu_safe_resources[Resource1, NonTriviallyMovableResource]()
    )
    assert_false(
        constrain_gpu_safe_resources[NonTriviallyMovableResource, Resource1]()
    )


def test_host_dictionary_kernel_views() raises:
    """Packed host tables expose the same trivial views as GPU kernels.

    Raises:
        Error: If table packing or an assertion fails.
    """
    comptime assert conforms_to(Int32DictView, TrivialRegisterPassable)
    comptime assert conforms_to(StringDictView, TrivialRegisterPassable)

    var integers = Int32Dict()
    integers[3] = 30
    var strings = StringDict()
    strings["café"] = 40
    var staged = ResourceEncoder()
    var integer_view = staged.pack_int32(integers)
    var string_view = staged.pack_string(strings)
    assert_equal(integer_view.get_or(3, -1), 30)
    assert_equal(integer_view.get_or(8, -1), -1)
    assert_equal(string_view.get_or("café", -1), 40)
    assert_equal(string_view.get_or("missing", -1), -1)
    assert_equal(staged.keep_alive(), 16)


def read_both_dictionaries(
    context: KernelContext[
        Filter().include[Int32](),
        Resources[Int32DictResource, StringDictResource](),
    ]
):
    """Reads two GPU-safe dictionary views in a CPU kernel.

    Args:
        context: Integer rows and the required dictionary resources.
    """
    var integers = context.resources.get[Int32DictResource]()
    var strings = context.resources.get[StringDictResource]()
    for entity in context:
        entity.get[Int32]() = integers.get_or(3, -1) + strings.get_or("a", -1)


def test_cpu_kernel_uses_packed_dictionary_views() raises:
    """CPU kernel binding keeps both packed tables alive for the call.

    Raises:
        Error: If execution or an assertion fails.
    """
    var world = World[Int32]()
    var integers = Int32DictResource()
    integers.entries[3] = 30
    var strings = StringDictResource()
    strings.entries["a"] = 12
    world.resources.add(integers^, strings^)
    var entity = world.storage.add_entity(Int32(0))
    var context = SystemContext(world)
    context.run[read_both_dictionaries]()
    assert_equal(world.storage.get[Int32](entity), 42)


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


comptime functions = __functions_in_module()


def main() raises:
    TestSuite.discover_tests[functions]().run()
