from larecs import (
    World,
    Entity,
    SystemContext,
    KernelContext,
    Filter,
    Resources,
    ResourceType,
    Captures,
    ReadCapture,
    MutCapture,
    read_capture,
    mut_capture,
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
    archetypes here. Before this fix, `SystemContext.run`'s host path gave
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


@fieldwise_init
struct History(ResourceType):
    var values: List[Int]


def test_cpu_closure_captures_and_heap_resources() raises:
    """Preserves captures and heap-owned resources across repeated kernel calls.
    """
    var world = World[Counter, Tag]()
    world.resources.add(History(List[Int]()), VisitCount(0))
    var first = world.storage.add_entity(Counter(1))
    var second = world.storage.add_entity(Counter(2), Tag(0))
    var increment = 3
    var visits = 0

    def update(
        context: KernelContext[
            Filter().include[Counter](), Resources[History, VisitCount]()
        ],
    ) {imm increment, mut visits}:
        """Records each updated row using immutable and mutable captures.

        Args:
            context: Matching component rows and shared resources.
        """
        ref history = context.resources.get[History]()
        ref count = context.resources.get[VisitCount]()
        for entity in context:
            entity.get[Counter]().v += increment
            history.values.append(entity.get[Counter]().v)
            count.value += 1
            visits += 1

    var context = SystemContext(world)
    for _ in range(100):
        context.run(update)

    assert_equal(visits, 200)
    assert_equal(world.resources.get[VisitCount]().value, 200)
    ref history = world.resources.get[History]()
    assert_equal(len(history.values), 200)
    assert_equal(history.values[0], 4)
    assert_equal(history.values[1], 5)
    assert_equal(history.values[198], 301)
    assert_equal(history.values[199], 302)
    assert_equal(world.storage.get[Counter](first).v, 301)
    assert_equal(world.storage.get[Counter](second).v, 302)


def test_cpu_closure_missing_resource_raises() raises:
    """Rejects missing resources before invoking a capturing kernel.

    Raises:
        Error: If setup fails or missing resources do not prevent execution.
    """
    var world = World[Counter]()
    _ = world.storage.add_entity(Counter(1))
    var called = False

    def missing_resource_kernel(
        context: KernelContext[
            Filter().include[Counter](), Resources[History, VisitCount]()
        ],
    ) {mut called}:
        """Records whether resource validation allowed execution.

        Args:
            context: Matching component rows and required resources.
        """
        called = True

    var context = SystemContext(world)
    with assert_raises():
        context.run(missing_resource_kernel)
    assert_false(called)


def test_cpu_closure_with_explicit_capture_bindings() raises:
    """Combines lexical captures with explicitly bound host-local values.

    Raises:
        Error: If setup, execution, or an assertion fails.
    """
    var world = World[Int32]()
    var entity = world.storage.add_entity(Int32(2))
    var factor: Int32 = 3
    var output: Int32 = 0
    var visits = 0
    comptime slots = Captures[ReadCapture[Int32], MutCapture[Int32]]()

    def bound_kernel(
        rows: KernelContext[Filter().include[Int32](), capture_spec=slots]
    ) {mut visits}:
        """Updates each row and both kinds of mutable capture.

        Args:
            rows: Components and explicit capture bindings.
        """
        for row in rows:
            row.get[Int32]() *= rows.captures.get[0]()
            rows.captures.get[1]() += row.get[Int32]()
            visits += 1

    var context = SystemContext(world)
    context.run(bound_kernel, read_capture(factor), mut_capture(output))
    assert_equal(visits, 1)
    assert_equal(factor, 3)
    assert_equal(output, 6)
    assert_equal(world.storage.get[Int32](entity), 6)


@fieldwise_init
struct DispatchAudit(ResourceType):
    var calls: Int
    var rows: Int
    var wrong_threads: Int


comptime MIXED_FILTER = Filter().write[Int32]().read[Counter]().exclude[
    Float32
]()


def audit_dispatch(
    context: KernelContext[MIXED_FILTER, Resources[DispatchAudit]()]
):
    """Records local bounds and exercises reordered read/write columns.

    Args:
        context: Component columns and the mutable audit resource.
    """
    ref audit = context.resources.get[DispatchAudit]()
    audit.calls += 1
    audit.rows += Int(context.length)
    audit.wrong_threads += Int(context.thread_count != 1)
    for entity in context:
        entity.set(Int32(entity.get[Counter]().v * 2))


def check_cpu_dispatch[groups: Int, use_closure: Bool]() raises:
    """Checks both callable forms across empty, single and multiple matches.

    Parameters:
        groups: Number of matching archetypes to populate (zero to two).
        use_closure: Whether to dispatch a capturing closure.

    Raises:
        Error: If setup, dispatch, or an assertion fails.
    """
    var world = World[Counter, Int32, Tag, Float32]()
    world.resources.add(DispatchAudit(0, 0, 0))
    var excluded = world.storage.add_entity(Counter(99), Int32(-1), Float32(0))
    var entities = List[Entity]()
    comptime if groups > 0:
        for i in range(3):
            entities.append(world.storage.add_entity(Counter(i + 1), Int32(-1)))
    comptime if groups > 1:
        for i in range(2):
            entities.append(
                world.storage.add_entity(Counter(i + 4), Int32(-1), Tag(0))
            )

    var calls = 0
    var rows = 0
    var wrong_threads = 0
    var factor = 2

    def captured(
        view: KernelContext[MIXED_FILTER],
    ) {mut calls, mut rows, mut wrong_threads, imm factor}:
        """Records local bounds and writes values using captured state.

        Args:
            view: The current archetype's read/write component columns.
        """
        calls += 1
        rows += Int(view.length)
        wrong_threads += Int(view.thread_count != 1)
        for entity in view:
            entity.set(Int32(entity.get[Counter]().v * factor))

    var context = SystemContext(world)
    # Repeated calls exercise resource pointer validity across helper returns.
    for _ in range(20):
        comptime if use_closure:
            context.run(captured)
        else:
            context.run[audit_dispatch]()

    comptime if not use_closure:
        calls = world.resources.get[DispatchAudit]().calls
        rows = world.resources.get[DispatchAudit]().rows
        wrong_threads = world.resources.get[DispatchAudit]().wrong_threads
    assert_equal(calls, groups * 20)
    assert_equal(rows, len(entities) * 20)
    assert_equal(wrong_threads, 0)
    for i in range(len(entities)):
        assert_equal(world.storage.get[Int32](entities[i]), Int32((i + 1) * 2))
        assert_equal(world.storage.get[Counter](entities[i]).v, i + 1)
    assert_equal(world.storage.get[Int32](excluded), -1)


def test_cpu_dispatch_shapes_and_access_modes() raises:
    """Covers both overloads with zero, one and two matching archetypes.

    Raises:
        Error: If any dispatch case fails.
    """
    comptime for groups in range(3):
        check_cpu_dispatch[groups, False]()
        check_cpu_dispatch[groups, True]()


def test_cpu_empty_query_still_requires_static_resources() raises:
    """An empty static CPU dispatch validates its required resources.

    Raises:
        Error: If the missing resource is accepted.
    """
    var world = World[Counter, Int32, Tag, Float32]()
    var context = SystemContext(world)
    with assert_raises():
        context.run[audit_dispatch]()


comptime functions = __functions_in_module()


def main() raises:
    TestSuite.discover_tests[functions]().run()
