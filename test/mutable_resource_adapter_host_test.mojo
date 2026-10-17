"""Mutable adapted resources on sequential and threaded host execution."""

from std.testing import (
    assert_equal,
    assert_true,
    assert_false,
    assert_raises,
    TestSuite,
)
from larecs import (
    World,
    SystemContext,
    KernelContext,
    Filter,
    Resources,
    ResourceAccess,
    BufferResource,
    ThreadedExecutionConfig,
    DevicePassableResource,
    ResourceAdapter,
    ResourceDeviceCache,
)
from scatter_fixture import (
    Cell,
    Seen,
    Scatter,
    ScatterFill,
    ScatterRead,
    ScatterAdapter,
    scatter_write,
    scatter_append,
    scatter_read,
    write_spec,
    read_write_spec,
    read_spec,
)


@fieldwise_init
struct Tag(TrivialRegisterPassable):
    """Splits entities into additional archetypes."""

    var value: Int32


def _world(workers: Int = 1) raises -> World[Cell, Int32, Seen, Tag]:
    """Creates a world whose threaded runs always use parallel chunks.

    Args:
        workers: Worker-task budget.

    Raises:
        Error: If the configuration is invalid.

    Returns:
        An empty world.
    """
    return World[Cell, Int32, Seen, Tag](
        execution_config=ThreadedExecutionConfig(
            workers=workers, chunks_per_worker=4, min_parallel_rows=0
        )
    )


def _populate(
    mut world: World[Cell, Int32, Seen, Tag], count: Int, cells: Int
) raises:
    """Adds entities with unique values over three archetypes.

    Entity `i` targets cell `i % cells` with value `i + 1`.

    Args:
        world: Target world.
        count: Number of entities.
        cells: Number of target cells.

    Raises:
        Error: If entity creation fails.
    """
    for i in range(count):
        var cell = Cell(Int32(i % cells))
        var value = Int32(i + 1)
        if i % 3 == 0:
            _ = world.storage.add_entity(cell, value, Seen(0))
        elif i % 3 == 1:
            _ = world.storage.add_entity(cell, value, Seen(0), Tag(1))
        else:
            _ = world.storage.add_entity(cell, value, Tag(2))


def _expected(first: Int, count: Int, cells: Int, cell: Int) -> List[Int32]:
    """Lists the sorted values that entities `first..first+count` insert in a cell.

    Args:
        first: First entity index.
        count: Number of entities.
        cells: Number of target cells.
        cell: Cell to list.

    Returns:
        Sorted expected values.
    """
    var result = List[Int32]()
    for i in range(first, first + count):
        if i % cells == cell:
            result.append(Int32(i + 1))
    sort(result)
    return result^


def _check_cells(grid: Scatter, first: Int, count: Int, cells: Int) raises:
    """Checks order-independent cell contents and the shared total.

    Args:
        grid: Finalized grid.
        first: First inserted entity index.
        count: Number of inserted entities.
        cells: Number of target cells.

    Raises:
        Error: If any cell or the total differs.
    """
    var total = Int32(0)
    for cell in range(cells):
        var expected = _expected(first, count, cells, cell)
        assert_equal(grid.values(cell), expected)
        for value in expected:
            total += value
    assert_equal(grid.total(), total)
    assert_equal(grid.dropped(), 0)


def test_view_selection() raises:
    """Checks the access-selected view types and compatibility alias."""
    comptime assert Scatter.View[False] == ScatterRead
    comptime assert Scatter.View[True] == ScatterFill
    comptime assert Scatter.KernelView == ScatterRead
    comptime assert (
        BufferResource[DType.int32].View[True]
        == BufferResource[DType.int32].KernelView
    )
    comptime assert write_spec.access[Scatter] == ResourceAccess.WRITE
    comptime assert read_write_spec.access[Scatter] == ResourceAccess.READ_WRITE
    comptime assert read_spec.access[Scatter] == ResourceAccess.READ
    comptime assert not ResourceAccess.WRITE.preserves_contents()
    comptime assert ResourceAccess.READ_WRITE.mutable()
    comptime assert not BufferResource[DType.int32].Adapter.supports_mutation


def test_write_resets_and_read_write_preserves() raises:
    """Fresh write output replaces old contents; read_write appends to them.

    Raises:
        Error: If contents, totals, or lifecycle counts differ.
    """
    var world = _world()
    world.resources.add(Scatter(4, 64))
    _populate(world, 30, 4)
    var context = SystemContext(world)
    context.run[scatter_write]()
    _check_cells(world.resources.read[Scatter](), 0, 30, 4)
    context.run[scatter_append]()
    ref grid = world.resources.read[Scatter]()
    var total = Int32(0)
    for cell in range(4):
        var expected = _expected(0, 30, 4, cell)
        expected.extend(_expected(0, 30, 4, cell))
        sort(expected)
        assert_equal(grid.values(cell), expected)
        for value in expected:
            total += value
    assert_equal(grid.total(), total)
    context.run[scatter_write]()
    _check_cells(world.resources.read[Scatter](), 0, 30, 4)
    assert_equal(world.resources.read[Scatter]().prepared, 3)
    assert_equal(world.resources.read[Scatter]().finalized, 3)


def test_read_view_sees_published_output() raises:
    """A read declaration selects the read view over finalized contents.

    Raises:
        Error: If a read kernel observes different counts.
    """
    var world = _world()
    world.resources.add(Scatter(3, 64))
    _populate(world, 20, 3)
    var context = SystemContext(world)
    context.run[scatter_write]()
    context.run[scatter_read]()
    for entity in world.storage.query[Filter().read[Cell, Seen]()]():
        var cell = Int(entity.get[Cell]().index)
        assert_equal(
            Int(entity.get[Seen]().count), len(_expected(0, 20, 3, cell))
        )
    # Reads neither prepare nor finalize mutable output.
    assert_equal(world.resources.read[Scatter]().prepared, 1)
    assert_equal(world.resources.read[Scatter]().finalized, 1)


def test_colliding_writers_reserve_distinct_slots() raises:
    """Every writer targeting one cell receives its own slot.

    Raises:
        Error: If values are lost or duplicated.
    """
    var world = _world()
    world.resources.add(Scatter(1, 200))
    _populate(world, 200, 1)
    var context = SystemContext(world)
    context.run[scatter_write]()
    _check_cells(world.resources.read[Scatter](), 0, 200, 1)
    assert_equal(world.resources.read[Scatter]().count(0), 200)


def test_capacity_overflow_reporting() raises:
    """Full cells drop and count writes; strict finalization raises after publication.

    Raises:
        Error: If overflow counts, clamping, or error propagation differ.
    """
    var world = _world()
    world.resources.add(Scatter(2, 5))
    _populate(world, 30, 2)
    var context = SystemContext(world)
    context.run[scatter_write]()
    ref grid = world.resources.read[Scatter]()
    assert_equal(grid.count(0), 5)
    assert_equal(grid.count(1), 5)
    assert_equal(grid.dropped(), 20)
    var total = Int32(0)
    for cell in range(2):
        var stored = grid.values(cell)
        assert_equal(len(stored), 5)
        for value in stored:
            assert_equal(Int(value - 1) % 2, cell)
            total += value
    assert_equal(grid.total(), total)

    world.resources.get[Scatter]().strict = True
    with assert_raises(contains="Scatter capacity exceeded: 20 dropped"):
        context.run[scatter_write]()
    # Outputs stay published, finalization ran once, and the lease ended.
    assert_equal(world.resources.read[Scatter]().dropped(), 20)
    assert_equal(world.resources.read[Scatter]().finalized, 2)
    world.resources.get[Scatter]() = Scatter(2, 64, strict=True)
    context.run[scatter_write]()
    _check_cells(world.resources.read[Scatter](), 0, 30, 2)


def test_empty_query_prepares_and_finalizes() raises:
    """Runs without matching rows still initialize fresh output and finalize.

    Raises:
        Error: If empty runs skip preparation, finalization, or reset.
    """
    var world = _world(4)
    world.resources.add(Scatter(2, 8))
    world.resources.get[Scatter]().counts[0] = 3
    world.resources.get[Scatter]().stats[0] = 9
    var context = SystemContext(world)
    context.run[scatter_append]()
    assert_equal(world.resources.read[Scatter]().count(0), 3)
    assert_equal(world.resources.read[Scatter]().total(), 9)
    context.run[scatter_write]()
    assert_equal(world.resources.read[Scatter]().count(0), 0)
    assert_equal(world.resources.read[Scatter]().total(), 0)
    world.resources.get[Scatter]().stats[0] = 9
    context.run[scatter_write, threaded=True]()
    assert_equal(world.resources.read[Scatter]().total(), 0)
    var selection = context._empty_selection()
    world.resources.get[Scatter]().stats[0] = 9
    selection.run[scatter_write]()
    selection^.release()
    assert_equal(world.resources.read[Scatter]().total(), 0)
    assert_equal(world.resources.read[Scatter]().prepared, 4)
    assert_equal(world.resources.read[Scatter]().finalized, 4)


def test_multiple_archetypes_and_repeated_runs() raises:
    """One preparation spans every archetype; repeated writes do not accumulate.

    Raises:
        Error: If output is reset per archetype or accumulates across writes.
    """
    var world = _world()
    world.resources.add(Scatter(5, 64))
    _populate(world, 90, 5)
    var context = SystemContext(world)
    for run in range(3):
        context.run[scatter_write]()
        _check_cells(world.resources.read[Scatter](), 0, 90, 5)
        assert_equal(world.resources.read[Scatter]().prepared, run + 1)
        assert_equal(world.resources.read[Scatter]().finalized, run + 1)


def test_threaded_writers() raises:
    """Concurrent host chunks share one fresh output and reserve distinct slots.

    Raises:
        Error: If threaded results differ from the sequential contract.
    """
    for workers in [1, 4]:
        var world = _world(workers)
        world.resources.add(Scatter(3, 512))
        _populate(world, 600, 3)
        var context = SystemContext(world)
        for run in range(2):
            context.run[scatter_write, threaded=True]()
            _check_cells(world.resources.read[Scatter](), 0, 600, 3)
            assert_equal(world.resources.read[Scatter]().prepared, run + 1)
            assert_equal(world.resources.read[Scatter]().finalized, run + 1)
        context.run[scatter_append, threaded=True]()
        assert_equal(world.resources.read[Scatter]().count(0), 400)
        assert_false(world._execution_active)
        assert_false(world.storage.is_locked())


def test_threaded_overflow() raises:
    """Concurrent writers count every dropped write exactly once.

    Raises:
        Error: If threaded overflow accounting differs.
    """
    var world = _world(4)
    world.resources.add(Scatter(2, 100))
    _populate(world, 600, 2)
    var context = SystemContext(world)
    context.run[scatter_write, threaded=True]()
    ref grid = world.resources.read[Scatter]()
    assert_equal(grid.count(0), 100)
    assert_equal(grid.count(1), 100)
    assert_equal(grid.dropped(), 400)
    var total = Int32(0)
    for cell in range(2):
        for value in grid.values(cell):
            total += value
    assert_equal(grid.total(), total)


def test_closure_and_selection_paths() raises:
    """Capturing host kernels and selections complete mutable output once.

    Raises:
        Error: If either entry point skips preparation or finalization.
    """
    var world = _world()
    world.resources.add(Scatter(2, 64))
    _populate(world, 12, 2)
    var context = SystemContext(world)
    var calls = 0

    def capture_write(
        rows: KernelContext[Filter().read[Cell, Int32](), write_spec]
    ) {mut calls}:
        calls += 1
        ref grid = rows.resources.get[Scatter]()
        for entity in rows:
            _ = grid.insert(Int(entity.get[Cell]().index), entity.get[Int32]())

    context.run(capture_write)
    assert_equal(calls, 3)
    _check_cells(world.resources.read[Scatter](), 0, 12, 2)
    with context.add_entities(Cell(0), Int32(100), count=4) as selection:
        selection.run[scatter_write]()
    ref grid = world.resources.read[Scatter]()
    assert_equal(
        grid.values(0), [Int32(100), Int32(100), Int32(100), Int32(100)]
    )
    assert_equal(grid.count(1), 0)
    assert_equal(grid.prepared, 2)
    assert_equal(grid.finalized, 2)


@fieldwise_init
struct HostCounter(DevicePassableResource):
    """Host-only mutable resource without concurrent-mutation support."""

    comptime Adapter = HostCounterAdapter
    var value: Int32


@fieldwise_init
struct HostCounterView(TrivialRegisterPassable):
    """Read view over the counter."""

    var value: Pointer[Int32, ImmUntrackedOrigin]


@fieldwise_init
struct HostCounterFill(TrivialRegisterPassable):
    """Unsynchronized increment view; safe only for sequential host kernels."""

    var value: Pointer[Int32, MutUntrackedOrigin]

    def add(self, delta: Int32):
        """Adds without synchronization.

        Args:
            delta: Increment.
        """
        self.value[] += delta


struct HostCounterAdapter(ResourceAdapter):
    """Supports sequential mutation only."""

    comptime Source = HostCounter
    comptime View[
        mutable: Bool
    ] = HostCounterFill if mutable else HostCounterView
    comptime supports_mutation = True

    @staticmethod
    def validate(source: Self.Source) raises:
        """Rejects negative counters.

        Args:
            source: Current counter.

        Raises:
            Error: If the counter is negative.
        """
        if source.value < 0:
            raise Error("Negative counter")

    @staticmethod
    def bind_host(source: Self.Source) raises -> Self.View[False]:
        """Borrows the counter.

        Args:
            source: Validated counter.

        Raises:
            Error: Never.

        Returns:
            Read view.
        """
        return {
            Pointer[Int32, ImmUntrackedOrigin](
                unsafe_from_address=Int(Pointer(to=source.value))
            )
        }

    @staticmethod
    def prepare_device(
        source: Self.Source, mut cache: ResourceDeviceCache
    ) raises -> Self.View[False]:
        """Uploads the counter.

        Args:
            source: Validated counter.
            cache: Leased cache.

        Raises:
            Error: If upload fails.

        Returns:
            Read view.
        """
        var values = [source.value]
        return {cache.upload[Int32](0, Span(values))}

    @staticmethod
    def bind_host_mutable[
        access: ResourceAccess
    ](mut source: Self.Source) raises -> Self.View[True]:
        """Resets fresh output and borrows the counter mutably.

        Parameters:
            access: `WRITE` or `READ_WRITE`.

        Args:
            source: Validated counter.

        Raises:
            Error: Never.

        Returns:
            Fill view.
        """
        comptime if access == ResourceAccess.WRITE:
            source.value = 0
        return {
            Pointer[Int32, MutUntrackedOrigin](
                unsafe_from_address=Int(Pointer(to=source.value))
            )
        }


def count_rows(
    rows: KernelContext[
        Filter().read[Int32](), Resources().read_write[HostCounter]()
    ]
):
    """Counts rows sequentially.

    Args:
        rows: Matching rows and the unsynchronized fill view.
    """
    ref counter = rows.resources.get[HostCounter]()
    for _ in rows:
        counter.add(1)


def test_sequential_only_adapter() raises:
    """Adapters without concurrent support still run sequential host kernels.

    Raises:
        Error: If sequential mutable host access fails.
    """
    var world = _world()
    world.resources.add(HostCounter(2))
    _populate(world, 9, 1)
    var context = SystemContext(world)
    context.run[count_rows]()
    assert_equal(world.resources.read[HostCounter]().value, 11)


def test_invocation_cleanup() raises:
    """Validation failures and finished runs release leases and keep revisions.

    Raises:
        Error: If leases remain or revisions do not advance.
    """
    var world = _world()
    world.resources.add(Scatter(2, 8))
    _populate(world, 4, 2)
    var context = SystemContext(world)
    world.resources.get[Scatter]().counts.append(0)
    with assert_raises(contains="Scatter buffers do not match dimensions"):
        context.run[scatter_write]()
    assert_equal(world.resources.read[Scatter]().prepared, 0)
    _ = world.resources.get[Scatter]().counts.pop()
    var before = world.resources._revision("scatter_fixture.Scatter")
    context.run[scatter_write]()
    assert_true(world.resources._revision("scatter_fixture.Scatter") > before)
    before = world.resources._revision("scatter_fixture.Scatter")
    context.run[scatter_read]()
    assert_equal(world.resources._revision("scatter_fixture.Scatter"), before)
    assert_equal(len(world.resources._leases), 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
