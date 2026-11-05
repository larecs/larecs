# SKIP_ASAN
# SKIP_DEBUG

"""Mutable adapted resources on the device, compared with host execution."""

from fixtures.finalization import (
    pair_world,
    write_pair,
    check_pair,
    seed_pair,
    preserve_pair,
)
from std.sys import has_accelerator
from std.testing import assert_equal, assert_true, assert_raises, TestSuite
from larecs import ExecutionBackend, World, SystemContext, Filter
from fixtures.scatter import (
    Cell,
    Seen,
    Scatter,
    scatter_write,
    scatter_append,
    scatter_read,
)


def _world(
    count: Int, cells: Int, capacity: Int
) raises -> World[Cell, Int32, Seen]:
    """Creates a world with entities over two archetypes and a scatter grid.

    Entity `i` targets cell `i % cells` with value `i + 1`.

    Args:
        count: Number of entities.
        cells: Number of cells.
        capacity: Slots per cell.

    Raises:
        Error: If entity creation fails.

    Returns:
        The populated world.
    """
    var world = World[Cell, Int32, Seen]()
    world.resources.add(Scatter(cells, capacity))
    for i in range(count):
        if i % 2 == 0:
            _ = world.storage.add_entity(Cell(Int32(i % cells)), Int32(i + 1))
        else:
            _ = world.storage.add_entity(
                Cell(Int32(i % cells)), Int32(i + 1), Seen(0)
            )
    return world^


def _check_cells(grid: Scatter, count: Int, cells: Int, copies: Int) raises:
    """Checks order-independent contents after `copies` insertions per entity.

    Args:
        grid: Finalized grid.
        count: Number of entities.
        cells: Number of cells.
        copies: Number of insertions of each entity value.

    Raises:
        Error: If any cell or the total differs.
    """
    var total = Int32(0)
    for cell in range(cells):
        var expected = List[Int32]()
        for i in range(count):
            if i % cells == cell:
                for _ in range(copies):
                    expected.append(Int32(i + 1))
                    total += Int32(i + 1)
        sort(expected)
        assert_equal(grid.values(cell), expected)
    assert_equal(grid.total(), total)
    assert_equal(grid.dropped(), 0)


def _skip(name: String):
    """Reports a skipped device test.

    Args:
        name: Test name.
    """
    print("SKIP:", name, "requires an accelerator")


def test_device_write_and_read_write() raises:
    """Device writes initialize fresh output; read_write preserves it.

    Raises:
        Error: If device results differ from the host contract.
    """
    comptime if has_accelerator():
        var world = _world(3000, 7, 1024)
        world.reuse_device_copies(True)
        var context = SystemContext(world)
        context.run[scatter_write, backend=ExecutionBackend.DEVICE]()
        _check_cells(world.resources.read[Scatter](), 3000, 7, 1)
        context.run[scatter_append, backend=ExecutionBackend.DEVICE]()
        _check_cells(world.resources.read[Scatter](), 3000, 7, 2)
        context.run[scatter_write, backend=ExecutionBackend.DEVICE]()
        _check_cells(world.resources.read[Scatter](), 3000, 7, 1)
        # Mutable sources are prepared on every run, even with copy reuse.
        assert_equal(world.resources.read[Scatter]().prepared, 3)
        assert_equal(world.resources.read[Scatter]().finalized, 3)
        # Host and device runs share one representation and contract.
        context.run[scatter_append]()
        _check_cells(world.resources.read[Scatter](), 3000, 7, 2)
        context.run[scatter_read, backend=ExecutionBackend.DEVICE]()
        for entity in world.storage.query[Filter().read[Seen]()]():
            assert_true(entity.get[Seen]().count > 0)
    else:
        _skip("test_device_write_and_read_write")


def test_device_collisions_and_overflow() raises:
    """Colliding device threads reserve distinct slots and count dropped writes.

    Raises:
        Error: If slots, totals, or overflow counts differ.
    """
    comptime if has_accelerator():
        # 5000 threads contend for two cell counters, 2500 per counter.
        var world = _world(5000, 2, 2500)
        var context = SystemContext(world)
        context.run[scatter_write, backend=ExecutionBackend.DEVICE]()
        _check_cells(world.resources.read[Scatter](), 5000, 2, 1)
        world.resources.get[Scatter]() = Scatter(2, 100, strict=True)
        with assert_raises(contains="Scatter capacity exceeded: 4800 dropped"):
            context.run[scatter_write, backend=ExecutionBackend.DEVICE]()
        # Published outputs remain and the world stays usable.
        ref grid = world.resources.read[Scatter]()
        assert_equal(grid.count(0), 100)
        assert_equal(grid.count(1), 100)
        assert_equal(grid.dropped(), 4800)
        var total = Int32(0)
        for cell in range(2):
            for value in grid.values(cell):
                total += value
        assert_equal(grid.total(), total)
        world.resources.get[Scatter]() = Scatter(2, 2500)
        context.run[scatter_write, backend=ExecutionBackend.DEVICE]()
        _check_cells(world.resources.read[Scatter](), 5000, 2, 1)
    else:
        _skip("test_device_collisions_and_overflow")


def test_device_empty_query() raises:
    """Empty device runs initialize fresh output and finalize without device work.

    Raises:
        Error: If empty runs skip preparation or finalization.
    """
    comptime if has_accelerator():
        var world = _world(0, 2, 4)
        world.resources.get[Scatter]().counts[1] = 2
        world.resources.get[Scatter]().stats[0] = 5
        var context = SystemContext(world)
        context.run[scatter_append, backend=ExecutionBackend.DEVICE]()
        assert_equal(world.resources.read[Scatter]().count(1), 2)
        context.run[scatter_write, backend=ExecutionBackend.DEVICE]()
        assert_equal(world.resources.read[Scatter]().count(1), 0)
        assert_equal(world.resources.read[Scatter]().total(), 0)
        assert_equal(world.resources.read[Scatter]().prepared, 2)
        assert_equal(world.resources.read[Scatter]().finalized, 2)
        assert_equal(world._last_device_upload.bytes, 0)
    else:
        _skip("test_device_empty_query")


def test_device_selection() raises:
    """Selected device runs share one fresh output.

    Raises:
        Error: If selected results differ.
    """
    comptime if has_accelerator():
        var world = _world(10, 2, 64)
        var context = SystemContext(world)
        with context.add_entities(Cell(1), Int32(50), count=300) as selection:
            selection.run[scatter_write, backend=ExecutionBackend.DEVICE]()
        ref grid = world.resources.read[Scatter]()
        assert_equal(grid.count(0), 0)
        assert_equal(grid.count(1), 64)
        assert_equal(grid.dropped(), 236)
        assert_equal(grid.total(), 64 * 50)
    else:
        _skip("test_device_selection")


def test_device_all_finalizers_run_after_error() raises:
    """Publishes both outputs and retains the first of two finalizer failures.

    Raises:
        Error: If device publication, finalization, or cleanup differs.
    """
    comptime if has_accelerator():
        var world = pair_world(32)
        world.reuse_device_copies(True)
        var context = SystemContext(world)
        for run in range(2):
            with assert_raises(
                contains="Scatter capacity exceeded: 31 dropped"
            ):
                context.run[write_pair, backend=ExecutionBackend.DEVICE]()
            check_pair(world, 32, run + 1)
        with context.add_entities(Int32(7), count=8) as selection:
            with assert_raises(contains="Scatter capacity exceeded: 7 dropped"):
                selection.run[write_pair, backend=ExecutionBackend.DEVICE]()
        check_pair(world, 8, 3)
    else:
        _skip("test_device_all_finalizers_run_after_error")


def test_device_empty_finalizers_run_after_error() raises:
    """Empty device runs complete all adapters without launching device work.

    Raises:
        Error: If empty completion skips a finalizer or changes the first error.
    """
    comptime if has_accelerator():
        var world = pair_world(0)
        seed_pair(world)
        var context = SystemContext(world)
        with assert_raises(contains="Scatter capacity exceeded: 31 dropped"):
            context.run[preserve_pair, backend=ExecutionBackend.DEVICE]()
        check_pair(world, 32, 1)
        assert_equal(world._last_device_upload.bytes, 0)
        var selection = context._empty_selection()
        with assert_raises(contains="Scatter capacity exceeded: 31 dropped"):
            selection.run[preserve_pair, backend=ExecutionBackend.DEVICE]()
        selection^.release()
        check_pair(world, 32, 2)
    else:
        _skip("test_device_empty_finalizers_run_after_error")


def main() raises:
    """Runs the mutable adapted resource regression suite.

    Raises:
        Error: If a test assertion or resource operation fails.
    """
    TestSuite.discover_tests[__functions_in_module()]().run()
