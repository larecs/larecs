"""Two independently adapted scatter resources for finalization regressions."""

from std.testing import assert_equal, assert_false
from larecs import (
    DevicePassableResource,
    ResourceAdapter,
    ResourceAccess,
    ResourceDeviceCache,
    Resources,
    KernelContext,
    Filter,
    World,
    ThreadedExecutionConfig,
)
from .scatter import Scatter, ScatterAdapter, ScatterRead, ScatterFill


@fieldwise_init
struct LaterScatter(DevicePassableResource):
    """Distinct resource whose finalizer must run after the first one fails."""

    comptime Adapter = LaterScatterAdapter
    var grid: Scatter


struct LaterScatterAdapter(ResourceAdapter):
    """Delegates the second resource's lifecycle to the scatter adapter."""

    comptime Source = LaterScatter
    comptime View[mutable: Bool] = ScatterFill if mutable else ScatterRead
    comptime supports_mutation = True
    comptime supports_concurrent_mutation = True

    @staticmethod
    def validate(source: Self.Source) raises:
        """Delegates validate for the later grid.

        Args:
            source: Later resource holding the grid.

        Raises:
            Error: If the scatter adapter operation fails.
        """
        ScatterAdapter.validate(source.grid)

    @staticmethod
    def bind_host(source: Self.Source) raises -> Self.View[False]:
        """Delegates bind host for the later grid.

        Args:
            source: Later resource holding the grid.

        Raises:
            Error: If the scatter adapter operation fails.

        Returns:
            The selected scatter view.
        """
        return ScatterAdapter.bind_host(source.grid)

    @staticmethod
    def prepare_device(
        source: Self.Source, mut cache: ResourceDeviceCache
    ) raises -> Self.View[False]:
        """Delegates prepare device for the later grid.

        Args:
            source: Later resource holding the grid.
            cache: Invocation cache for this resource.

        Raises:
            Error: If the scatter adapter operation fails.

        Returns:
            The selected scatter view.
        """
        return ScatterAdapter.prepare_device(source.grid, cache)

    @staticmethod
    def bind_host_mutable[
        access: ResourceAccess
    ](mut source: Self.Source) raises -> Self.View[True]:
        """Delegates bind host mutable for the later grid.

        Parameters:
            access: Mutable access mode.

        Args:
            source: Later resource holding the grid.

        Raises:
            Error: If the scatter adapter operation fails.

        Returns:
            The selected scatter view.
        """
        return ScatterAdapter.bind_host_mutable[access](source.grid)

    @staticmethod
    def prepare_device_mutable[
        access: ResourceAccess
    ](
        mut source: Self.Source, mut cache: ResourceDeviceCache
    ) raises -> Self.View[True]:
        """Delegates prepare device mutable for the later grid.

        Parameters:
            access: Mutable access mode.

        Args:
            source: Later resource holding the grid.
            cache: Invocation cache for this resource.

        Raises:
            Error: If the scatter adapter operation fails.

        Returns:
            The selected scatter view.
        """
        return ScatterAdapter.prepare_device_mutable[access](source.grid, cache)

    @staticmethod
    def stage_device_results[
        access: ResourceAccess
    ](mut source: Self.Source, mut cache: ResourceDeviceCache) raises:
        """Delegates stage device results for the later grid.

        Parameters:
            access: Mutable access mode.

        Args:
            source: Later resource holding the grid.
            cache: Invocation cache for this resource.

        Raises:
            Error: If the scatter adapter operation fails.
        """
        ScatterAdapter.stage_device_results[access](source.grid, cache)

    @staticmethod
    def finalize[access: ResourceAccess](mut source: Self.Source) raises:
        """Delegates finalize for the later grid.

        Parameters:
            access: Mutable access mode.

        Args:
            source: Later resource holding the grid.

        Raises:
            Error: If the scatter adapter operation fails.
        """
        ScatterAdapter.finalize[access](source.grid)


comptime pair_spec = Resources().write[Scatter, LaterScatter]()


def write_pair(rows: KernelContext[Filter().read[Int32](), pair_spec]):
    """Overflows both resources with different dropped-write counts.

    Args:
        rows: Matching values and both mutable scatter views.
    """
    ref first = rows.resources.get[Scatter]()
    ref later = rows.resources.get[LaterScatter]()
    for entity in rows:
        _ = first.insert(0, entity.get[Int32]())
        _ = later.insert(0, entity.get[Int32]())


def pair_world(count: Int) raises -> World[Int32]:
    """Creates two strict resources with capacities one and two.

    Args:
        count: Number of identical input values.

    Raises:
        Error: If world configuration or entity creation fails.

    Returns:
        World configured to exercise multiple host workers.
    """
    var world = World[Int32](
        execution_config=ThreadedExecutionConfig(
            workers=4, chunks_per_worker=4, min_parallel_rows=0
        )
    )
    world.resources.add(Scatter(1, 1, strict=True))
    world.resources.add(LaterScatter(Scatter(1, 2, strict=True)))
    for _ in range(count):
        _ = world.storage.add_entity(Int32(7))
    return world^


def check_pair(world: World[Int32], count: Int, runs: Int) raises:
    """Checks published data, both finalizers, and released execution leases.

    Args:
        world: Completed world.
        count: Number of values inserted per run.
        runs: Expected preparation and finalization count.

    Raises:
        Error: If publication, finalization, or cleanup differs.
    """
    ref first = world.resources.read[Scatter]()
    ref later = world.resources.read[LaterScatter]().grid
    assert_equal(first.prepared, runs)
    assert_equal(first.finalized, runs)
    assert_equal(later.prepared, runs)
    assert_equal(later.finalized, runs)
    assert_equal(first.count(0), min(count, 1))
    assert_equal(later.count(0), min(count, 2))
    assert_equal(Int(first.total()), min(count, 1) * 7)
    assert_equal(Int(later.total()), min(count, 2) * 7)
    assert_equal(Int(first.dropped()), max(count - 1, 0))
    assert_equal(Int(later.dropped()), max(count - 2, 0))
    assert_equal(later.values(0), List[Int32](length=min(count, 2), fill=7))
    assert_equal(len(world.resources._leases), 0)
    assert_false(world._execution_active)
    assert_false(world.storage.is_locked())


def seed_pair(mut world: World[Int32]) raises:
    """Seeds overflowing preserved outputs for runs without matching rows.

    Args:
        world: Empty world holding both strict scatter resources.

    Raises:
        Error: If mutable resource access fails.
    """
    ref first = world.resources.get[Scatter]()
    first.counts[0] = 32
    first.slots[0] = 7
    first.stats[0] = 7
    first.stats[1] = 31
    ref later = world.resources.get[LaterScatter]().grid
    later.counts[0] = 32
    later.slots[0] = 7
    later.slots[1] = 7
    later.stats[0] = 14
    later.stats[1] = 30


def preserve_pair(
    rows: KernelContext[
        Filter().read[Int32](), Resources().read_write[Scatter, LaterScatter]()
    ]
):
    """Preserves seeded outputs in empty-query finalization tests.

    Args:
        rows: Empty matching range and both preserved mutable views.
    """
    _ = rows
