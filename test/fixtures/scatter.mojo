"""Synthetic mutable scatter resource shared by the mutable adapter tests.

Entities insert values into per-cell slot lists. Writers reserve distinct slots
with atomic counters, add values to a shared total, and count writes dropped
because a cell is full. The same kernel runs sequentially, threaded, and on a
device; slot order within a cell depends on scheduling.
"""

from std.sys import size_of
from larecs import (
    AtomicView,
    DevicePassableResource,
    Filter,
    KernelContext,
    ResourceAccess,
    ResourceAdapter,
    ResourceDeviceCache,
    Resources,
)


@fieldwise_init
struct Cell(TrivialRegisterPassable):
    """Target cell of one entity."""

    var index: Int32


@fieldwise_init
struct Seen(TrivialRegisterPassable):
    """Per-entity result of a read-view kernel."""

    var count: Int32


@fieldwise_init
struct ScatterRead(TrivialRegisterPassable):
    """Read view over published slots, counters, and shared statistics."""

    var slots: Pointer[Int32, ImmUntrackedOrigin]
    var counts: Pointer[UInt32, ImmUntrackedOrigin]
    var stats: Pointer[Int32, ImmUntrackedOrigin]
    var cells: Int
    var capacity: Int

    def count(self, cell: Int) -> Int:
        """Returns the number of stored values in a cell.

        Args:
            cell: Validated cell index.

        Returns:
            The finalized slot count, at most the capacity.
        """
        return min(Int(self.counts[unsafe_offset=cell]), self.capacity)

    def total(self) -> Int32:
        """Returns the sum of all stored values.

        Returns:
            Shared total reduction.
        """
        return self.stats[unsafe_offset=0]


@fieldwise_init
struct ScatterFill(TrivialRegisterPassable):
    """Mutable view reserving slots with atomics; the descriptor stays immutable.
    """

    var slots: Pointer[Int32, MutUntrackedOrigin]
    var counts: Pointer[UInt32, MutUntrackedOrigin]
    var stats: Pointer[Int32, MutUntrackedOrigin]
    var cells: Int
    var capacity: Int

    def insert(self, cell: Int, value: Int32) -> Bool:
        """Reserves a distinct slot in a cell and stores a value there.

        Args:
            cell: Validated cell index.
            value: Value written into the reserved slot.

        Returns:
            Whether a slot was available; full cells count a dropped write.
        """
        var slot = Int(
            AtomicView[True, UInt32, MutUntrackedOrigin](
                unsafe_pointer=Pointer(to=self.counts[unsafe_offset=cell])
            ).fetch_add(1)
        )
        if slot >= self.capacity:
            _ = AtomicView[True, Int32, MutUntrackedOrigin](
                unsafe_pointer=Pointer(to=self.stats[unsafe_offset=1])
            ).fetch_add(1)
            return False
        # Reserved slots are disjoint, so this plain store cannot race.
        self.slots[unsafe_offset=cell * self.capacity + slot] = value
        _ = AtomicView[True, Int32, MutUntrackedOrigin](
            unsafe_pointer=Pointer(to=self.stats[unsafe_offset=0])
        ).fetch_add(value)
        return True


struct Scatter(DevicePassableResource):
    """Owns per-cell slots, counters, statistics, and lifecycle counters."""

    comptime Adapter = ScatterAdapter
    var cells: Int
    var capacity: Int
    var slots: List[Int32]
    var counts: List[UInt32]
    var stats: List[Int32]
    """Shared total at index 0 and dropped writes at index 1."""
    var strict: Bool
    """Whether finalization reports dropped writes as an error."""
    var prepared: Int
    """Number of mutable preparations, one per invocation."""
    var finalized: Int
    """Number of finalizations, one per successful mutable invocation."""

    def __init__(out self, cells: Int, capacity: Int, strict: Bool = False):
        """Creates an empty grid with consistent buffer sizes.

        Args:
            cells: Number of cells.
            capacity: Slots per cell.
            strict: Whether finalization raises on dropped writes.
        """
        self.cells = cells
        self.capacity = capacity
        self.slots = List[Int32](length=cells * capacity, fill=0)
        self.counts = List[UInt32](length=cells, fill=0)
        self.stats = [Int32(0), Int32(0)]
        self.strict = strict
        self.prepared = 0
        self.finalized = 0

    def count(self, cell: Int) -> Int:
        """Returns the number of stored values in a cell.

        Args:
            cell: Cell index.

        Returns:
            Finalized slot count.
        """
        return Int(self.counts[cell])

    def values(self, cell: Int) -> List[Int32]:
        """Returns a cell's stored values in ascending order.

        Slot order depends on scheduling, so callers compare sorted values.

        Args:
            cell: Cell index.

        Returns:
            Sorted stored values.
        """
        var result = List[Int32]()
        for slot in range(self.count(cell)):
            result.append(self.slots[cell * self.capacity + slot])
        sort(result)
        return result^

    def total(self) -> Int32:
        """Returns the shared total.

        Returns:
            Sum of stored values.
        """
        return self.stats[0]

    def dropped(self) -> Int32:
        """Returns the number of writes rejected by full cells.

        Returns:
            Dropped write count.
        """
        return self.stats[1]


struct ScatterAdapter(ResourceAdapter):
    """Prepares fresh or preserved backing buffers on either target."""

    comptime Source = Scatter
    comptime View[mutable: Bool] = ScatterFill if mutable else ScatterRead
    comptime supports_mutation = True
    comptime supports_concurrent_mutation = True

    @staticmethod
    def validate(source: Self.Source) raises:
        """Checks dimensions and buffer sizes.

        Args:
            source: Current grid.

        Raises:
            Error: If dimensions are negative, overflow, or mismatch buffers.
        """
        if source.cells < 0 or source.capacity < 0:
            raise Error("Negative scatter dimensions")
        if (
            source.capacity != 0
            and source.cells > Int(Int32.MAX) // source.capacity
        ):
            raise Error("Scatter dimensions overflow")
        if (
            len(source.slots) != source.cells * source.capacity
            or len(source.counts) != source.cells
            or len(source.stats) != 2
        ):
            raise Error("Scatter buffers do not match dimensions")

    @staticmethod
    def bind_host(source: Self.Source) raises -> Self.View[False]:
        """Borrows host buffers in a read view.

        Args:
            source: Validated grid.

        Raises:
            Error: Never; required by the adapter contract.

        Returns:
            Read view over host buffers.
        """
        return {
            Pointer[Int32, ImmUntrackedOrigin](
                unsafe_from_address=Int(source.slots.unsafe_ptr())
            ),
            Pointer[UInt32, ImmUntrackedOrigin](
                unsafe_from_address=Int(source.counts.unsafe_ptr())
            ),
            Pointer[Int32, ImmUntrackedOrigin](
                unsafe_from_address=Int(source.stats.unsafe_ptr())
            ),
            source.cells,
            source.capacity,
        }

    @staticmethod
    def prepare_device(
        source: Self.Source, mut cache: ResourceDeviceCache
    ) raises -> Self.View[False]:
        """Uploads current buffers for a read view.

        Args:
            source: Validated grid.
            cache: Leased source-type cache.

        Raises:
            Error: If allocation or upload fails.

        Returns:
            Read view over device buffers.
        """
        return {
            cache.upload[Int32](0, Span(source.slots)),
            cache.upload[UInt32](1, Span(source.counts)),
            cache.upload[Int32](2, Span(source.stats)),
            source.cells,
            source.capacity,
        }

    @staticmethod
    def bind_host_mutable[
        access: ResourceAccess
    ](mut source: Self.Source) raises -> Self.View[True]:
        """Resets host output for `WRITE` and returns a fill view.

        Parameters:
            access: `WRITE` or `READ_WRITE`.

        Args:
            source: Validated grid.

        Raises:
            Error: Never; required by the adapter contract.

        Returns:
            Fill view writing host buffers directly.
        """
        source.prepared += 1
        comptime if not access.preserves_contents():
            for ref value in source.slots:
                value = 0
            for ref count in source.counts:
                count = 0
            source.stats[0] = 0
            source.stats[1] = 0
        return {
            Pointer[Int32, MutUntrackedOrigin](
                unsafe_from_address=Int(source.slots.unsafe_ptr())
            ),
            Pointer[UInt32, MutUntrackedOrigin](
                unsafe_from_address=Int(source.counts.unsafe_ptr())
            ),
            Pointer[Int32, MutUntrackedOrigin](
                unsafe_from_address=Int(source.stats.unsafe_ptr())
            ),
            source.cells,
            source.capacity,
        }

    @staticmethod
    def prepare_device_mutable[
        access: ResourceAccess
    ](
        mut source: Self.Source, mut cache: ResourceDeviceCache
    ) raises -> Self.View[True]:
        """Initializes or uploads device buffers and returns a fill view.

        Parameters:
            access: `WRITE` fills zeros; `READ_WRITE` uploads current contents.

        Args:
            source: Validated grid.
            cache: Leased source-type cache.

        Raises:
            Error: If allocation or upload fails.

        Returns:
            Fill view over device buffers.
        """
        source.prepared += 1
        comptime if access.preserves_contents():
            return {
                cache.upload_mutable[Int32](0, Span(source.slots)),
                cache.upload_mutable[UInt32](1, Span(source.counts)),
                cache.upload_mutable[Int32](2, Span(source.stats)),
                source.cells,
                source.capacity,
            }
        else:
            return {
                cache.fill[Int32](0, len(source.slots), 0),
                cache.fill[UInt32](1, len(source.counts), 0),
                cache.fill[Int32](2, len(source.stats), 0),
                source.cells,
                source.capacity,
            }

    @staticmethod
    def stage_device_results[
        access: ResourceAccess
    ](mut source: Self.Source, mut cache: ResourceDeviceCache) raises:
        """Stages every output buffer for publication.

        Parameters:
            access: `WRITE` or `READ_WRITE`.

        Args:
            source: Grid receiving outputs after completion.
            cache: Cache holding this invocation's buffers.

        Raises:
            Error: If staging fails.
        """
        cache.download(0, Span(source.slots))
        cache.download(1, Span(source.counts))
        cache.download(2, Span(source.stats))

    @staticmethod
    def finalize[access: ResourceAccess](mut source: Self.Source) raises:
        """Clamps reservation counters and reports dropped writes.

        Parameters:
            access: `WRITE` or `READ_WRITE`.

        Args:
            source: Grid holding published outputs.

        Raises:
            Error: If the grid is strict and writes were dropped.
        """
        source.finalized += 1
        for ref count in source.counts:
            count = min(count, UInt32(source.capacity))
        if source.strict and source.stats[1] > 0:
            raise Error(t"Scatter capacity exceeded: {source.stats[1]} dropped")


comptime cell_values = Filter().read[Cell, Int32]()
comptime write_spec = Resources().write[Scatter]()
comptime read_write_spec = Resources().read_write[Scatter]()
comptime read_spec = Resources().read[Scatter]()


def scatter_write(context: KernelContext[cell_values, write_spec]):
    """Inserts every entity's value into fresh output.

    Args:
        context: Matching rows and the fill view over fresh output.
    """
    ref grid = context.resources.get[Scatter]()
    for entity in context:
        _ = grid.insert(Int(entity.get[Cell]().index), entity.get[Int32]())


def scatter_append(context: KernelContext[cell_values, read_write_spec]):
    """Inserts every entity's value after existing contents.

    Args:
        context: Matching rows and the fill view over preserved output.
    """
    ref grid = context.resources.get[Scatter]()
    for entity in context:
        _ = grid.insert(Int(entity.get[Cell]().index), entity.get[Int32]())


def scatter_read(
    context: KernelContext[Filter().read[Cell]().include[Seen](), read_spec]
):
    """Stores each entity's cell count through the read view.

    Args:
        context: Matching rows and the read view.
    """
    ref grid = context.resources.get[Scatter]()
    for entity in context:
        entity.get[Seen]().count = Int32(
            grid.count(Int(entity.get[Cell]().index))
        )
