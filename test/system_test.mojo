from larecs import (
    World,
    Entity,
    SystemContext,
    KernelContext,
    Filter,
    Resources,
    ResourceType,
)
from larecs.test_utils import SmallWorld, FlexibleComponent
from std.testing import *


@fieldwise_init
struct Counter(Copyable):
    var v: Int


@fieldwise_init
struct Tag(Copyable):
    var t: Int


@fieldwise_init
struct VisitCount(ResourceType):
    var value: Int


def count_visits(
    context: KernelContext[Filter().include[Counter](), Resources[VisitCount]()]
):
    """Increments `VisitCount` once per row the kernel actually visits."""
    ref visits = context.resources.get[VisitCount]()
    for entity in context:
        visits.value += 1
        _ = entity.get[Counter]()


def test_system_context_run_thin_overload_visits_each_archetype_once() raises:
    """A filter matching multiple archetypes must visit each row exactly once.

    `Filter().include[Counter]()` matches two differently-composed
    archetypes here. Before this fix, `SystemContext.run`'s CPU path gave
    every per-archetype `KernelContext` the *summed* row count across every
    matching archetype (instead of that archetype's own row count), so a
    kernel run against N matching archetypes visited N times too many rows
    in total -- reading/writing past the end of every archetype smaller
    than the sum. With three entities in one archetype and two in another,
    the bug would drive the visit count to (3 + 2) * 2 = 10 instead of 5.
    """
    var world = World[Counter, Tag]()
    world.resources.add(VisitCount(0))

    # Archetype A: Counter only. Built with `add_entity` (singular), not
    # `add_entities`: the latter returns an iterator that holds the
    # world's query lock until it is dropped, and discarding it via `_ =`
    # was observed to keep that lock held into the next statement --
    # tripping `add_entity`'s own "world is locked" check below. A plain
    # `add_entity` call returns an owned `Entity` and holds no lock.
    for _ in range(3):
        _ = world.storage.add_entity(Counter(0))
    # Archetype B: Counter + Tag. Also matches Filter().include[Counter]().
    for _ in range(2):
        _ = world.storage.add_entity(Counter(0), Tag(0))

    var context = SystemContext(world)
    context.run[count_visits]()

    assert_equal(world.resources.get[VisitCount]().value, 5)


def test_system_context_run_capturing_overload_visits_each_archetype_once() raises:
    """The capturing-closure `run` overload has the same per-archetype bug.

    Mirrors `test_system_context_run_thin_overload_visits_each_archetype_once`
    for `SystemContext.run(kernel_func)`, which builds its own
    `KernelContext` independently of the non-capturing overload and had the
    same over-iteration bug.
    """
    var world = World[Counter, Tag]()

    for _ in range(3):
        _ = world.storage.add_entity(Counter(0))
    for _ in range(2):
        _ = world.storage.add_entity(Counter(0), Tag(0))

    var visits = 0

    def count_visits_capturing(
        context: KernelContext[Filter().include[Counter]()],
    ) {mut visits}:
        for entity in context:
            visits += 1
            _ = entity.get[Counter]()

    var context = SystemContext(world)
    context.run(count_visits_capturing)

    assert_equal(visits, 5)


def overwrite_flexible_component_0_x(
    context: KernelContext[Filter().include[FlexibleComponent[0]]()],
):
    """Sets every matching entity's `x` field to `9.0` via `set`, keeping `y`.
    """
    for entity in context:
        var value = entity.get[FlexibleComponent[0]]()
        value.x = 9.0
        entity.set(value)


def test_kernel_mutates_matching_entities_in_order() raises:
    """A kernel run through `SystemContext` mutates each entity it visits.

    `HostStorage.query` is read-only, so component mutation now only
    happens inside a kernel run through `SystemContext.run`; this covers
    the mutation coverage (`.set()`, per-entity correctness across
    iteration) that used to live on `HostStorage.query` results directly.
    """
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

    var context = SystemContext(world)
    context.run[overwrite_flexible_component_0_x]()

    for i in range(n):
        var value = world.storage.get[FlexibleComponent[0]](entities[i])
        assert_equal(value.x, 9.0)
        assert_equal(value.y, Float32(i))


comptime functions = __functions_in_module()


def main() raises:
    TestSuite.discover_tests[functions]().run()
