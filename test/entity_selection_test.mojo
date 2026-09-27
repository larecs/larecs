"""Tests for locked, exact-range entity selections."""

from std.testing import (
    assert_equal,
    assert_false,
    assert_true,
    assert_raises,
    TestSuite,
)

from larecs import (
    Entity,
    Components,
    EntityRange,
    Filter,
    KernelContext,
    ResourceType,
    Resources,
    SystemContext,
    World,
)
from larecs.error import WorldError


@fieldwise_init
struct Counter(Copyable, Movable):
    """Integer component used by selection tests."""

    var value: Int


@fieldwise_init
struct Tag(Copyable, Movable):
    """Marker-like integer component used by selection tests."""

    var value: Int


@fieldwise_init
struct Visits(ResourceType):
    """Shared visit counter used by selected execution tests."""

    var value: Int


def increment_selected(
    context: KernelContext[Filter().include[Counter](), Resources[Visits]()],
):
    """Increments selected counters and records each visited row.

    Args:
        context: Selected counter rows and the shared visit resource.
    """
    ref visits = context.resources.get[Visits]()
    for entity in context:
        entity.get[Counter]().value += 1
        visits.value += 1


def count_selected_tags(
    context: KernelContext[
        Filter().include[Counter, Tag](), Resources[Visits]()
    ],
):
    """Records selected rows carrying both counter and tag components.

    Args:
        context: Selected counter-and-tag rows and the visit resource.
    """
    ref visits = context.resources.get[Visits]()
    for _ in context:
        visits.value += 1


def test_selection_move_release_and_empty_lifecycle() raises:
    """A move transfers one guard and explicit release unlocks the world.

    Raises:
        Error: If acquiring the test guard or an assertion fails.
    """
    var world = World[Int]()
    var context = SystemContext(world)
    var selection = context._empty_selection()
    assert_true(selection._is_world_locked())
    assert_equal(len(selection), 0)

    var moved = selection^
    assert_true(moved._is_world_locked())
    moved^.release()
    assert_false(world.storage.is_locked())


def test_selection_destruction_releases_once() raises:
    """Destruction releases a nonempty selection's guard exactly once.

    Raises:
        Error: If acquiring the test guard or an assertion fails.
    """
    var world = World[Int]()
    var ranges: List[EntityRange] = [EntityRange(0, 2, 3)]
    var context = SystemContext(world)
    var selection = context._empty_selection()
    selection._ranges = ranges^
    assert_equal(len(selection), 3)
    assert_true(selection._is_world_locked())
    _ = selection^
    assert_false(world.storage.is_locked())


def test_create_add_replace_remove_chain() raises:
    """A consuming mutation chain retains exact membership and one lock.

    Raises:
        Error: If an operation or assertion fails.
    """
    var world = World[Counter, Tag]()
    var context = SystemContext(world)
    var selection = context.add_entities(Counter(1), count=4)
    assert_equal(len(selection), 4)
    var with_tags = selection^.add(Tag(7))
    assert_equal(len(with_tags), 4)
    var replaced = with_tags^.replace[remove=Components[Counter](),](Counter(9))
    assert_equal(len(replaced), 4)
    var counters_only = replaced^.remove[Tag]()
    assert_equal(len(counters_only), 4)
    counters_only^.release()

    var count = 0
    for row in world.storage.query[Filter().include[Counter]()]():
        assert_equal(row.get[Counter]().value, 9)
        assert_false(row.has[Tag]())
        count += 1
    assert_equal(count, 4)


def test_context_filtered_add_returns_only_modified_rows() raises:
    """Context mutations exclude nonmatching and preexisting destination rows.

    Raises:
        Error: If an operation or assertion fails.
    """
    var world = World[Counter, Tag]()
    _ = world.storage.add_entity(Counter(1))
    _ = world.storage.add_entity(Counter(2))
    _ = world.storage.add_entity(Counter(100), Tag(3))
    var context = SystemContext(world)
    var selection = context.add[
        Tag, filter=Filter().include[Counter]().exclude[Tag]()
    ](Tag(8))
    assert_equal(len(selection), 2)
    selection^.release()

    var tagged = 0
    for row in world.storage.query[Filter().include[Counter, Tag]()]():
        if row.get[Counter]().value < 100:
            assert_equal(row.get[Tag]().value, 8)
        tagged += 1
    assert_equal(tagged, 3)


def test_internal_authorization_rejects_wrong_owner_and_conflict() raises:
    """The narrow runtime check rejects another manager and another lock.

    Raises:
        Error: If acquiring locks or assertions fail.
    """
    var first = World[Int]()
    var second = World[Int]()
    var first_lock = first.storage._lock()
    with assert_raises(contains=WorldError.world_is_locked.msg()):
        first.storage._assert_selection_authorized(
            Int(Pointer(to=second.storage._locks)), first_lock
        )
    var other_lock = first.storage._lock()
    with assert_raises(contains=WorldError.world_is_locked.msg()):
        first.storage._assert_selection_authorized(
            Int(Pointer(to=first.storage._locks)), first_lock
        )
    first.storage._unlock(other_lock)
    first.storage._assert_selection_authorized(
        Int(Pointer(to=first.storage._locks)), first_lock
    )
    first.storage._unlock(first_lock)


def test_selected_cpu_execution_is_bounded_reusable_and_filtered() raises:
    """CPU kernels visit only selected matching rows across repeated calls.

    Raises:
        Error: If execution or an assertion fails.
    """
    var world = World[Counter, Tag]()
    world.resources.add(Visits(0))
    var untouched = world.storage.add_entity(Counter(50))
    var context = SystemContext(world)
    var selection = context.add_entities(Counter(1), count=3)
    selection.run[increment_selected]()
    selection.run[increment_selected]()

    var lexical_visits = 0

    def add_ten(
        kernel_context: KernelContext[Filter().include[Counter]()],
    ) {mut lexical_visits}:
        """Adds ten through a lexical CPU closure.

        Args:
            kernel_context: Selected counter rows.
        """
        for entity in kernel_context:
            entity.get[Counter]().value += 10
            lexical_visits += 1

    selection.run(add_ten)
    var before_no_match = lexical_visits
    selection.run[count_selected_tags]()
    assert_equal(lexical_visits, before_no_match)
    selection^.release()

    assert_equal(world.storage.get[Counter](untouched).value, 50)
    assert_equal(world.resources.get[Visits]().value, 6)
    assert_equal(lexical_visits, 3)
    var changed = 0
    for row in world.storage.query[Filter().include[Counter]()]():
        if row.get_entity() != untouched:
            assert_equal(row.get[Counter]().value, 13)
            changed += 1
    assert_equal(changed, 3)


def test_disjoint_partial_ranges_preserve_unselected_rows_and_locations() raises:
    """Partial swap-removal mutates only selected IDs and keeps lookups valid.

    Raises:
        Error: If mutation, lookup, or an assertion fails.
    """
    var world = World[Counter, Tag]()
    var entities = List[Entity]()
    for i in range(6):
        entities.append(world.storage.add_entity(Counter(i)))

    var context = SystemContext(world)
    var selection = context._empty_selection()
    selection._ranges.append(EntityRange(1, 1, 1))
    selection._ranges.append(EntityRange(1, 4, 1))
    var tagged = selection^.add(Tag(5))
    assert_equal(len(tagged), 2)
    tagged^.release()

    for i in range(6):
        assert_equal(world.storage.get[Counter](entities[i]).value, i)
        if i == 1 or i == 4:
            assert_equal(world.storage.get[Tag](entities[i]).value, 5)
        else:
            assert_false(world.storage.has[Tag](entities[i]))


def test_context_replace_across_archetypes_and_empty_results() raises:
    """Context replacement spans archetypes and an empty chain stays locked.

    Raises:
        Error: If mutation or an assertion fails.
    """
    var world = World[Counter, Tag]()
    var first = world.storage.add_entity(Counter(1))
    var second = world.storage.add_entity(Counter(2), Tag(2))
    var context = SystemContext(world)
    var replaced = context.replace[
        remove=Components[Counter](),
        filter=Filter().include[Counter](),
    ](Counter(7))
    assert_equal(len(replaced), 2)
    var empty = replaced^.remove[
        Tag, filter=Filter().include[Tag]().exclude[Counter]()
    ]()
    assert_equal(len(empty), 0)
    assert_true(empty._is_world_locked())
    empty^.release()
    assert_equal(world.storage.get[Counter](first).value, 7)
    assert_equal(world.storage.get[Counter](second).value, 7)


def main() raises:
    """Runs entity-selection tests.

    Raises:
        Error: If any discovered test fails.
    """
    TestSuite.discover_tests[__functions_in_module()]().run()
