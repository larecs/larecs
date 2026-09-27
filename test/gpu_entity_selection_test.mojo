# SKIP_ASAN
# SKIP_DEBUG

"""Hardware tests for packed GPU execution on entity selections."""

from std.sys import has_accelerator
from std.testing import assert_equal, TestSuite

from std.gpu import global_idx
from std.sys.info import is_gpu

from larecs import (
    Captures,
    Entity,
    EntityRange,
    Filter,
    KernelContext,
    MutCapture,
    ReadCapture,
    Resources,
    ResourceType,
    SystemContext,
    World,
    mut_capture,
    read_capture,
)


@fieldwise_init
struct Position(Copyable, TrivialRegisterPassable):
    """GPU-safe scalar position."""

    var value: Float32


@fieldwise_init
struct Tag(Copyable, TrivialRegisterPassable):
    """GPU-safe marker component."""

    var value: Int32


@fieldwise_init
struct VisitTotal(ResourceType, TrivialRegisterPassable):
    """GPU-safe selected-row visit total."""

    var value: Int32


comptime bindings = Captures[ReadCapture[Float32], MutCapture[Int32]]()
"""Input increment and copied-back selected row count."""


def add_one(context: KernelContext[Filter().include[Position]()]):
    """Adds one to each packed selected position.

    Args:
        context: Packed selected position rows.
    """
    for entity in context:
        entity.get[Position]().value += 1.0


def update_with_bindings(
    context: KernelContext[
        Filter().include[Position]().write[Tag](),
        Resources[VisitTotal](),
        bindings,
    ],
):
    """Updates selected components, a resource, and a mutable capture.

    Args:
        context: Packed rows, resource, and explicit capture bindings.
    """
    for entity in context:
        entity.get[Position]().value += context.captures.get[0]()
        entity.set(Tag(9))

    comptime if is_gpu():
        if global_idx.x != 0:
            return
    context.resources.get[VisitTotal]().value += context.length
    context.captures.get[1]() += context.length


def test_gpu_selection_packs_nonzero_ranges_and_reuses_storage() raises:
    """GPU upload and scatter touch only selected rows across changing sizes.

    Raises:
        Error: If device execution or an assertion fails.
    """
    comptime if has_accelerator():
        var world = World[Position, Tag]()
        var untouched = world.storage.add_entity(Position(100.0))
        var context = SystemContext(world)

        var first = context.add_entities(Position(1.0), count=4)
        first.run[add_one, on_gpu=True]()
        first.run[add_one, on_gpu=True]()
        first^.release()

        var second = context.add_entities(Position(10.0), Tag(1), count=2)
        second.run[add_one, on_gpu=True]()
        second^.release()

        assert_equal(world.storage.get[Position](untouched).value, 100.0)
        var values_3 = 0
        var values_11 = 0
        for row in world.storage.query[Filter().include[Position]()]():
            var value = row.get[Position]().value
            if value == 3.0:
                values_3 += 1
            elif value == 11.0:
                values_11 += 1
        assert_equal(values_3, 4)
        assert_equal(values_11, 2)


def test_gpu_selection_preserves_resources_captures_and_write_only() raises:
    """Selected GPU execution copies resources, captures, and writes back.

    Raises:
        Error: If device execution or an assertion fails.
    """
    comptime if has_accelerator():
        var world = World[Position, Tag]()
        world.resources.add(VisitTotal(0))
        var context = SystemContext(world)
        var selection = context.add_entities(Position(2.0), Tag(0), count=3)
        var amount: Float32 = 4.0
        var processed: Int32 = 0
        selection.run[update_with_bindings, on_gpu=True](
            read_capture(amount), mut_capture(processed)
        )
        selection^.release()

        assert_equal(processed, 3)
        assert_equal(world.resources.get[VisitTotal]().value, 3)
        for row in world.storage.query[Filter().include[Position, Tag]()]():
            assert_equal(row.get[Position]().value, 6.0)
            assert_equal(row.get[Tag]().value, 9)


def test_gpu_selection_packs_disjoint_ranges_across_archetypes() raises:
    """One launch packs disjoint spans from multiple archetypes exactly.

    Raises:
        Error: If device execution or an assertion fails.
    """
    comptime if has_accelerator():
        var world = World[Position, Tag]()
        var plain = List[Entity]()
        for i in range(5):
            plain.append(world.storage.add_entity(Position(Float32(i))))
        var tagged = world.storage.add_entity(Position(20.0), Tag(1))

        var context = SystemContext(world)
        var selection = context._empty_selection()
        selection._ranges.append(EntityRange(1, 1, 1))
        selection._ranges.append(EntityRange(1, 3, 1))
        selection._ranges.append(EntityRange(2, 0, 1))
        selection.run[add_one, on_gpu=True]()
        selection^.release()

        for i in range(5):
            var expected = Float32(i)
            if i == 1 or i == 3:
                expected += 1.0
            assert_equal(world.storage.get[Position](plain[i]).value, expected)
        assert_equal(world.storage.get[Position](tagged).value, 21.0)


def main() raises:
    """Runs GPU entity-selection tests.

    Raises:
        Error: If any discovered test fails.
    """
    TestSuite.discover_tests[__functions_in_module()]().run()
