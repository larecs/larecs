"""Fill a shared per-cell grid from entities without captures.

Each entity inserts its value into the slot list of its cell. The kernel
receives the grid's writer view through `context.resources.get[Grid]()`;
it needs no `MutCapture`. The adapter prepares fresh output once per run,
writers reserve distinct slots with atomic counters, and the adapter
finalizes counts after completion. The same kernel runs sequentially,
threaded, and on a device when one is available.

Run with `pixi run mojo run -I src examples/scatter_resource.mojo`.
"""

from std.sys import has_accelerator
from std.testing import assert_equal
from larecs import (
    AtomicView,
    DevicePassableResource,
    Filter,
    KernelContext,
    ResourceAccess,
    ResourceAdapter,
    ResourceDeviceCache,
    Resources,
    SystemContext,
    ThreadedExecutionConfig,
    World,
)


@fieldwise_init
struct Cell(TrivialRegisterPassable):
    """Target cell of an entity."""

    var index: Int32


@fieldwise_init
struct GridRead(TrivialRegisterPassable):
    """Read view over finalized slot counts."""

    var counts: Pointer[UInt32, ImmUntrackedOrigin]

    def count(self, cell: Int) -> Int:
        """Returns the number of values stored in a cell.

        Args:
            cell: Cell index.

        Returns:
            Finalized slot count.
        """
        return Int(self.counts[unsafe_offset=cell])


@fieldwise_init
struct GridFill(TrivialRegisterPassable):
    """Writer view; the descriptor is immutable, its buffers are shared."""

    var slots: Pointer[Int32, MutUntrackedOrigin]
    var counts: Pointer[UInt32, MutUntrackedOrigin]
    var dropped: Pointer[UInt32, MutUntrackedOrigin]
    var capacity: Int

    def insert(self, cell: Int, value: Int32):
        """Reserves a distinct slot with an atomic counter and fills it.

        Args:
            cell: Cell index.
            value: Value to store.
        """
        var slot = Int(
            AtomicView[True, UInt32, MutUntrackedOrigin](
                unsafe_pointer=Pointer(to=self.counts[unsafe_offset=cell])
            ).fetch_add(1)
        )
        if slot < self.capacity:
            self.slots[unsafe_offset=cell * self.capacity + slot] = value
        else:
            _ = AtomicView[True, UInt32, MutUntrackedOrigin](
                unsafe_pointer=Pointer(to=self.dropped[])
            ).fetch_add(1)


struct Grid(DevicePassableResource):
    """Owns slots, per-cell counters, and a dropped-write counter."""

    comptime Adapter = GridAdapter
    var capacity: Int
    var slots: List[Int32]
    var counts: List[UInt32]
    var dropped: List[UInt32]

    def __init__(out self, cells: Int, capacity: Int):
        """Creates an empty grid.

        Args:
            cells: Number of cells.
            capacity: Slots per cell.
        """
        self.capacity = capacity
        self.slots = List[Int32](length=cells * capacity, fill=0)
        self.counts = List[UInt32](length=cells, fill=0)
        self.dropped = [UInt32(0)]


def _mut[
    T: TrivialRegisterPassable
](values: List[T]) -> Pointer[T, MutUntrackedOrigin]:
    """Addresses host backing storage for a writer view.

    Parameters:
        T: Element type.

    Args:
        values: Leased source buffer.

    Returns:
        Untracked mutable pointer valid during the invocation.
    """
    return Pointer[T, MutUntrackedOrigin](
        unsafe_from_address=Int(values.unsafe_ptr())
    )


struct GridAdapter(ResourceAdapter):
    """Selects GridRead for `read` and GridFill for `write`/`read_write`."""

    comptime Source = Grid
    comptime View[mutable: Bool] = GridFill if mutable else GridRead
    comptime supports_mutation = True
    # Slots are reserved atomically and written disjointly.
    comptime supports_concurrent_mutation = True

    @staticmethod
    def validate(source: Self.Source) raises:
        """Checks buffer sizes.

        Args:
            source: Current grid.

        Raises:
            Error: If buffers do not match the capacity.
        """
        if len(source.slots) != len(source.counts) * source.capacity:
            raise Error("Grid slots do not match cells and capacity")

    @staticmethod
    def bind_host(source: Self.Source) raises -> Self.View[False]:
        """Borrows host counts.

        Args:
            source: Validated grid.

        Raises:
            Error: Never.

        Returns:
            Read view.
        """
        return {
            Pointer[UInt32, ImmUntrackedOrigin](
                unsafe_from_address=Int(source.counts.unsafe_ptr())
            )
        }

    @staticmethod
    def prepare_device(
        source: Self.Source, mut cache: ResourceDeviceCache
    ) raises -> Self.View[False]:
        """Uploads counts for a read view.

        Args:
            source: Validated grid.
            cache: Leased cache.

        Raises:
            Error: If upload fails.

        Returns:
            Read view.
        """
        return {cache.upload[UInt32](1, Span(source.counts))}

    @staticmethod
    def bind_host_mutable[
        access: ResourceAccess
    ](mut source: Self.Source) raises -> Self.View[True]:
        """Resets output for `write`, then borrows host buffers.

        Parameters:
            access: `WRITE` or `READ_WRITE`.

        Args:
            source: Validated grid.

        Raises:
            Error: Never.

        Returns:
            Writer view over host buffers.
        """
        comptime if not access.preserves_contents():
            for ref count in source.counts:
                count = 0
            source.dropped[0] = 0
        return {
            _mut(source.slots),
            _mut(source.counts),
            _mut(source.dropped),
            source.capacity,
        }

    @staticmethod
    def prepare_device_mutable[
        access: ResourceAccess
    ](
        mut source: Self.Source, mut cache: ResourceDeviceCache
    ) raises -> Self.View[True]:
        """Initializes or uploads device buffers.

        Parameters:
            access: `WRITE` fills zeros; `READ_WRITE` uploads current contents.

        Args:
            source: Validated grid.
            cache: Leased cache on the world's device queue.

        Raises:
            Error: If allocation or upload fails.

        Returns:
            Writer view over device buffers.
        """
        comptime if access.preserves_contents():
            return {
                cache.upload_mutable[Int32](0, Span(source.slots)),
                cache.upload_mutable[UInt32](1, Span(source.counts)),
                cache.upload_mutable[UInt32](2, Span(source.dropped)),
                source.capacity,
            }
        else:
            return {
                cache.fill[Int32](0, len(source.slots), 0),
                cache.fill[UInt32](1, len(source.counts), 0),
                cache.fill[UInt32](2, 1, 0),
                source.capacity,
            }

    @staticmethod
    def stage_device_results[
        access: ResourceAccess
    ](mut source: Self.Source, mut cache: ResourceDeviceCache) raises:
        """Stages outputs for publication after completion.

        Parameters:
            access: `WRITE` or `READ_WRITE`.

        Args:
            source: Grid receiving outputs.
            cache: Cache holding this invocation's buffers.

        Raises:
            Error: If staging fails.
        """
        cache.download(0, Span(source.slots))
        cache.download(1, Span(source.counts))
        cache.download(2, Span(source.dropped))

    @staticmethod
    def finalize[access: ResourceAccess](mut source: Self.Source) raises:
        """Clamps reservation counters to the capacity.

        Parameters:
            access: `WRITE` or `READ_WRITE`.

        Args:
            source: Grid holding published outputs.

        Raises:
            Error: Never.
        """
        for ref count in source.counts:
            count = min(count, UInt32(source.capacity))


def fill_grid(
    context: KernelContext[
        Filter().read[Cell, Int32](), Resources().write[Grid]()
    ]
):
    """Inserts every entity into fresh grid output.

    Args:
        context: Matching rows and the grid's writer view.
    """
    ref grid = context.resources.get[Grid]()
    for entity in context:
        grid.insert(Int(entity.get[Cell]().index), entity.get[Int32]())


def check(grid: Grid) raises:
    """Checks that each of the 4 cells received 250 values and one overflow.

    Args:
        grid: Finalized grid.

    Raises:
        Error: If counts or dropped writes differ.
    """
    for cell in range(4):
        assert_equal(Int(grid.counts[cell]), 250)
    assert_equal(Int(grid.dropped[0]), 4)


def main() raises:
    """Fills the grid sequentially, threaded, and on a device if available.

    Raises:
        Error: If execution or a result check fails.
    """
    var world = World[Cell, Int32](
        execution_config=ThreadedExecutionConfig(workers=4, min_parallel_rows=0)
    )
    world.resources.add(Grid(cells=4, capacity=250))
    for i in range(1004):
        _ = world.storage.add_entity(Cell(Int32(i % 4)), Int32(i))
    var context = SystemContext(world)

    context.run[fill_grid]()
    check(world.resources.read[Grid]())
    context.run[fill_grid, threaded=True]()
    check(world.resources.read[Grid]())
    comptime if has_accelerator():
        context.run[fill_grid, on_device=True]()
        check(world.resources.read[Grid]())
        print("Filled the grid on host, threaded host, and device.")
    else:
        print("Filled the grid on host and threaded host; no accelerator.")
