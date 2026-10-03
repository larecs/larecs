"""Shared CPU execution preserves exact ranges and invocation-wide bindings."""

from std.testing import (
    assert_equal,
    assert_false,
    assert_true,
    assert_raises,
    TestSuite,
)
from larecs import (
    Captures,
    Entity,
    EntityRange,
    Filter,
    KernelContext,
    MutCapture,
    ReadCapture,
    ResourceType,
    Resources,
    SystemContext,
    World,
    mut_capture,
    read_capture,
)


@fieldwise_init
struct History(ResourceType):
    """Heap-backed resource recording range lengths and visited values."""

    var lengths: List[Int]
    var values: List[Int32]


comptime slots = Captures[ReadCapture[Int32], MutCapture[Int32]]()
"""Increment and running total shared across all execution ranges."""


comptime cpu_filter = Filter().include[Int32]()
"""Component access shared by the ordinary and selected range checks."""


def update_rows(rows: KernelContext[cpu_filter, Resources[History](), slots]):
    """Updates a range and records its values through shared host bindings.

    Args:
        rows: One matching range with resources and explicit captures.
    """
    ref history = rows.resources.get[History]()
    history.lengths.append(Int(rows.length))
    for row in rows:
        row.set(row.get[Int32]() + rows.captures.get[0]())
        rows.captures.get[1]() += row.get[Int32]()
        history.values.append(row.get[Int32]())


def _check_ranges[selected: Bool, closure: Bool]() raises:
    """Checks all CPU entry points against independently expected membership.

    Parameters:
        selected: Whether to run bounded disjoint selected ranges.
        closure: Whether to invoke a lexical closure or thin kernel.

    Raises:
        Error: If setup, execution, or verification fails.
    """
    var world = World[Int32, Float32, UInt8]()
    world.resources.add(History(List[Int](), List[Int32]()))
    var entities = List[Entity]()
    for i in range(6):
        entities.append(world.storage.add_entity(Int32(10 + i)))
    for i in range(3):
        entities.append(world.storage.add_entity(Int32(20 + i), Float32(0)))
    _ = world.storage.add_entity(Float32(0))
    # Keep an empty matching archetype to check that no zero-length call occurs.
    var removed = world.storage.add_entity(Int32(99), UInt8(0))
    world.storage.remove_entity(removed)
    var increment = Int32(2)
    var total = Int32(0)
    var lexical_calls = 0

    def update_closure(
        rows: KernelContext[cpu_filter, Resources[History](), slots]
    ) {mut lexical_calls}:
        """Checks lexical captures alongside explicit captures and resources.

        Args:
            rows: One matching CPU range.
        """
        lexical_calls += 1
        update_rows(rows)

    var context = SystemContext(world)
    comptime if selected:
        var selection = context._empty_selection()
        var plain_index = world.storage._entity_locations[
            entities[0].get_id()
        ].archetype_index
        var tagged_index = world.storage._entity_locations[
            entities[6].get_id()
        ].archetype_index
        selection._ranges.append(EntityRange(plain_index, 1, 2))
        selection._ranges.append(EntityRange(plain_index, 5, 1))
        selection._ranges.append(EntityRange(tagged_index, 1, 1))
        selection._ranges.append(EntityRange(plain_index, 0, 0))
        for _ in range(2):
            comptime if closure:
                selection.run(
                    update_closure, read_capture(increment), mut_capture(total)
                )
            else:
                selection.run[update_rows](
                    read_capture(increment), mut_capture(total)
                )
        assert_equal(len(selection), 4)
        assert_true(selection._is_world_locked())
        selection^.release()
    else:
        for _ in range(2):
            comptime if closure:
                context.run(
                    update_closure, read_capture(increment), mut_capture(total)
                )
            else:
                context.run[update_rows](
                    read_capture(increment), mut_capture(total)
                )

    assert_false(world.storage.is_locked())
    var expected_visits = 0
    var expected_total = Int32(0)
    for i in range(9):
        var eligible = True
        comptime if selected:
            eligible = eligible and (i == 1 or i == 2 or i == 5 or i == 7)
        var initial = Int32(10 + i if i < 6 else 20 + i - 6)
        assert_equal(
            world.storage.get[Int32](entities[i]),
            initial + Int32(4 if eligible else 0),
        )
        if eligible:
            expected_visits += 2
            expected_total += initial * 2 + 6
    assert_equal(total, expected_total)
    assert_equal(increment, 2)
    ref history = world.resources.get[History]()
    assert_equal(len(history.values), expected_visits)
    var expected_ranges = 2
    comptime if selected:
        expected_ranges += 1
    assert_equal(len(history.lengths), expected_ranges * 2)
    for length in history.lengths:
        assert_true(length > 0)
    comptime if closure:
        assert_equal(lexical_calls, expected_ranges * 2)


def test_cpu_ranges_and_bindings() raises:
    """All four CPU forms preserve disjoint membership and shared bindings.

    Raises:
        Error: If a range, binding, or filter contract is violated.
    """
    comptime for selected in range(2):
        comptime for closure in range(2):
            _check_ranges[Bool(selected), Bool(closure)]()


def _check_empty[closure: Bool, selected: Bool]() raises:
    """Validates missing resources even when no range matches.

    Parameters:
        closure: Whether to use the value-taking CPU overload.
        selected: Whether to execute through an empty selection.

    Raises:
        Error: If an empty match invokes a kernel or skips resource validation.
    """
    var world = World[Int32]()
    var calls = 0

    def empty_kernel(
        rows: KernelContext[
            Filter().include[Int32](), Resources[History](), slots
        ]
    ) {mut calls}:
        """Records unexpected invocation on an empty match.

        Args:
            rows: Empty execution context that must never be constructed.
        """
        calls += 1
        update_rows(rows)

    var increment = Int32(2)
    var total = Int32(17)
    var context = SystemContext(world)
    comptime if selected:
        var selection = context._empty_selection()
        with assert_raises():
            comptime if closure:
                selection.run(
                    empty_kernel, read_capture(increment), mut_capture(total)
                )
            else:
                selection.run[update_rows](
                    read_capture(increment), mut_capture(total)
                )
        assert_true(selection._is_world_locked())
        selection._world[].resources.add(History(List[Int](), List[Int32]()))
        comptime if closure:
            selection.run(
                empty_kernel, read_capture(increment), mut_capture(total)
            )
        else:
            selection.run[update_rows](
                read_capture(increment), mut_capture(total)
            )
        selection^.release()
    else:
        with assert_raises():
            comptime if closure:
                context.run(
                    empty_kernel, read_capture(increment), mut_capture(total)
                )
            else:
                context.run[update_rows](
                    read_capture(increment), mut_capture(total)
                )
        context.world[].resources.add(History(List[Int](), List[Int32]()))
        comptime if closure:
            context.run(
                empty_kernel, read_capture(increment), mut_capture(total)
            )
        else:
            context.run[update_rows](
                read_capture(increment), mut_capture(total)
            )
    assert_equal(calls, 0)
    assert_equal(total, 17)
    assert_false(world.storage.is_locked())


def test_empty_cpu_matches_validate_resources() raises:
    """Missing resources fail in both CPU overloads with empty membership.

    Raises:
        Error: If empty-match validation or lock cleanup fails.
    """
    comptime for selected in range(2):
        comptime for closure in range(2):
            _check_empty[Bool(closure), Bool(selected)]()


def excluded_rows(
    rows: KernelContext[
        Filter().include[Int32]().exclude[Float32](), capture_spec=slots
    ]
):
    """Updates only rows that do not carry the excluded component.

    Args:
        rows: Filtered rows and shared explicit captures.
    """
    for row in rows:
        row.get[Int32]() += rows.captures.get[0]()
        rows.captures.get[1]() += row.get[Int32]()


def _check_filtered[selected: Bool]() raises:
    """Checks exclusion and exclusive filters on both CPU range sources.

    Parameters:
        selected: Whether to intersect a saved selection with the filters.

    Raises:
        Error: If filtering, execution, or an assertion fails.
    """
    var world = World[Int32, Float32]()
    var plain = world.storage.add_entity(Int32(1))
    var tagged = world.storage.add_entity(Int32(10), Float32(0))
    _ = world.storage.add_entity(Float32(0))
    var increment = Int32(2)
    var total = Int32(0)
    var visits = 0

    def exclusive_rows(
        rows: KernelContext[
            Filter().include[Int32]().exclusive(), capture_spec=slots
        ]
    ) {mut visits}:
        """Updates exactly the Int32-only archetype.

        Args:
            rows: Exclusively filtered rows and explicit captures.
        """
        for row in rows:
            row.get[Int32]() += rows.captures.get[0]()
            rows.captures.get[1]() += row.get[Int32]()
            visits += 1

    var context = SystemContext(world)
    comptime if selected:
        var selection = context._select[Filter()]()
        selection.run[excluded_rows](
            read_capture(increment), mut_capture(total)
        )
        selection.run(
            exclusive_rows, read_capture(increment), mut_capture(total)
        )
        assert_equal(len(selection), 3)
        selection^.release()
    else:
        context.run[excluded_rows](read_capture(increment), mut_capture(total))
        context.run(exclusive_rows, read_capture(increment), mut_capture(total))
    assert_equal(world.storage.get[Int32](plain), 5)
    assert_equal(world.storage.get[Int32](tagged), 10)
    assert_equal(total, 8)
    assert_equal(visits, 1)
    assert_false(world.storage.is_locked())


def test_cpu_exclusion_and_exclusive_filters() raises:
    """Ordinary and selected CPU paths preserve filter intersections.

    Raises:
        Error: If either range source executes an ineligible row.
    """
    _check_filtered[False]()
    _check_filtered[True]()


comptime functions = __functions_in_module()


def main() raises:
    """Runs the CPU execution contract tests.

    Raises:
        Error: If a contract test fails.
    """
    TestSuite.discover_tests[functions]().run()
