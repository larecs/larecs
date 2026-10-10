"""Paired partition/reordering maintenance, scans, and complete cell workloads."""

from std.benchmark import keep
from std.sys import size_of
from std.time import perf_counter_ns
from std.testing import assert_equal, assert_true
from larecs import (
    World,
    Entity,
    Filter,
    SpatialClassifier,
    SystemContext,
    KernelContext,
    Resources,
    ResourceType,
)
from larecs.entity import EntityAccessor


comptime Payload = SIMD[DType.int64, 8]
comptime BenchWorld = World[Int, Payload, Float64]


@fieldwise_init
struct Policy(SpatialClassifier):
    """Use the exact application cell identity as the cluster key."""

    comptime Accessor = EntityAccessor[Filter().read[Int]()]

    def classify(self, entity: Self.Accessor) raises -> UInt64:
        """Return the current cell key.

        Args:
            entity: Read-only input row.

        Raises:
            Error: The classifier interface permits errors.

        Returns:
            The exact nonnegative cell key.
        """
        return UInt64(entity.get[Int]())


@fieldwise_init
struct ScanSum(ResourceType):
    """Consumed reduction shared across CPU block invocations."""

    var value: Int64


def scan(
    context: KernelContext[Filter().read[Payload](), Resources[ScanSum]()]
):
    """Read every payload lane once through ordinary CPU execution.

    Args:
        context: Prepared block or archetype range with the shared reduction.
    """
    var total = Int64(0)
    for row in context:
        total += row.get[Payload]().reduce_add()
    context.resources.get[ScanSum]().value += total


def prepare(
    rows: Int, group: Int, stride: Int, partitioned: Bool
) raises -> BenchWorld:
    """Construct identical scrambled identities and establish the chosen layout.

    Args:
        rows: Power-of-two row count.
        group: Identities per cluster across both logical archetypes.
        stride: Key gaps for sparse cells.
        partitioned: Choose cluster blocks or the current reordering control.

    Raises:
        Error: If setup or initial maintenance fails.

    Returns:
        An owned world with two logical archetypes and identity-valued payloads.
    """
    var world = BenchWorld()
    for i in range(rows):
        var key = (((i * 109) % rows) // group) * stride
        if i % 2:
            _ = world.storage.add_entity(key, Payload(i + 1), Float64(i))
        else:
            _ = world.storage.add_entity(key, Payload(i + 1))
    world.resources.add(ScanSum(0))
    world.register_spatial_classifier[Filter().read[Int]()](
        Policy(), partitioned=partitioned
    )
    world.maintain_spatial()
    return world^


def validate(
    mut world: BenchWorld,
    rows: Int,
    group: Int,
    stride: Int,
    updates: Int,
    frames: Int,
) raises:
    """Check every identity, payload lane, final input, and placement outside timing.

    Args:
        world: World to validate without marking classifier inputs.
        rows: Expected number of live entities.
        group: Initial identities per cell.
        stride: Initial key spacing.
        updates: Updated identities per frame.
        frames: Number of completed frames across all samples.

    Raises:
        Error: If any input, payload, location, or placement is invalid.
    """
    var seen = List[Bool](fill=False, length=rows)
    var count = 0
    for row in world.storage.query[Filter().read[Int, Payload]()]():
        var entity = row.get_entity()
        var id = Int(entity.get_id())
        assert_true(not seen[id - 1])
        seen[id - 1] = True
        var initial = (((id - 1) * 109) % rows) // group
        var expected = (
            (initial + (frames if id <= updates else 0)) % (rows // group)
        ) * stride
        assert_equal(row.get[Int](), expected)
        assert_equal(row.get[Payload](), Payload(id))
        var location = world.storage._entity_locations[entity.get_id()]
        ref block = world.storage._archetypes[location.archetype_index]
        assert_equal(block.get_entity(location.entity_index), entity)
        if world.storage._spatial_partitioned:
            assert_equal(block._partition_key.value(), UInt64(expected))
            assert_true(len(block) <= 256)
        count += 1
    assert_equal(count, rows)
    if not world.storage._spatial_partitioned:
        for block in world.storage._archetypes:
            var previous = 0
            for i in range(len(block)):
                var key = block.get_component[Int](i)
                assert_true(i == 0 or key >= previous)
                previous = key


def cell_workload(
    mut world: BenchWorld, cells: Int, stride: Int
) raises -> Int64:
    """Aggregate all lanes per cell and compute cyclic adjacent-cell interactions.

    Args:
        world: Identically updated world in either layout.
        cells: Number of possible occupied cells.
        stride: Distance between cell keys.

    Raises:
        Error: If query setup fails.

    Returns:
        Exact integer checksum of neighboring cell aggregate products.
    """
    var totals = List[Int64](fill=0, length=cells)
    for row in world.storage.query[Filter().read[Int, Payload]()]():
        totals[row.get[Int]() // stride] += row.get[Payload]().reduce_add()
    var result = Int64(0)
    for cell in range(cells):
        result += totals[cell] * totals[(cell + 1) % cells]
    return result


def sample(
    mut world: BenchWorld,
    rows: Int,
    group: Int,
    stride: Int,
    updates: Int,
    mode: Int,
    cadence: Int,
) raises -> Float64:
    """Time complete bounded frames with updates and all chosen maintenance costs.

    Args:
        world: Maintained world reused across samples.
        rows: Entity count.
        group: Initial identities per cell.
        stride: Cell key spacing.
        updates: Distinct identities moved per frame.
        mode: 0 maintenance, 1 ordinary query scan, 2 CPU scan, 3 complete cell frame.
        cadence: Maintenance every this many frames; final frame is maintained.

    Raises:
        Error: If mutation, maintenance, queries, or CPU execution fail.

    Returns:
        Nanoseconds per frame in a fixed batch of sixteen frames.
    """
    var query_sum = Int64(0)
    var start = perf_counter_ns()
    for frame in range(16):
        for id in range(1, updates + 1):
            ref key = world.storage.get[Int](Entity(id))
            key = ((key // stride + 1) % (rows // group)) * stride
        if (frame + 1) % cadence == 0:
            world.maintain_spatial()
        if mode == 1:
            query_sum = 0
            for row in world.storage.query[Filter().read[Payload]()]():
                query_sum += row.get[Payload]().reduce_add()
            keep(query_sum)
        elif mode == 2:
            world.resources.get[ScanSum]().value = 0
            var context = SystemContext(world)
            context.run[scan]()
            keep(context.world[].resources.get[ScanSum]().value)
        elif mode == 3:
            keep(cell_workload(world, rows // group, stride))
        else:
            keep(world.storage._entity_locations[1].entity_index)
    var elapsed = Float64(perf_counter_ns() - start) / 16.0
    if mode == 1:
        assert_equal(query_sum, Int64(rows) * Int64(rows + 1) * 4)
    elif mode == 2:
        assert_equal(
            world.resources.get[ScanSum]().value,
            Int64(rows) * Int64(rows + 1) * 4,
        )
    return elapsed


def memory(
    world: BenchWorld,
    rows: Int,
    distribution: Int,
    partitioned: Bool,
    *,
    after_movement: Bool = False,
):
    """Report capacity-derived owned buffer bytes and block occupancy.

    Excludes allocator bookkeeping, graph/pool allocations, device storage,
    classifier configuration, and transient maintenance/query/workload scratch.
    Payloads are trivial, so component capacities count all payload storage.

    Args:
        world: Maintained world to inspect without invalidation.
        rows: Live rows.
        distribution: 0 uniform, 1 dense, 2 singleton sparse.
        partitioned: Whether this is the partitioned sample.
        after_movement: Report retained memory after fully moving samples.
    """
    var bytes = (
        world.storage._archetypes.capacity()
        * size_of[world.HostStorage.Archetype]()
    )
    var slots = 0
    var blocks = 0
    var allocations = 1
    for block in world.storage._archetypes:
        if block._partition_key:
            blocks += 1
        slots += block._storage._capacity
        bytes += block._entities.capacity() * size_of[Entity]()
        if block._entities.capacity() > 0:
            allocations += 1
        comptime for i in range(len(world.component_types)):
            comptime T = world.component_types[i]
            if block.get_mask().get(i):
                bytes += block._storage._capacity * size_of[T]()
                if block._storage._capacity > 0:
                    allocations += 1
    bytes += (
        world.storage._entity_locations.capacity()
        * size_of[type_of(world.storage._entity_locations[0])]()
    )
    bytes += world.storage._spatial_keys.capacity() * size_of[UInt64]()
    bytes += world.storage._spatial_marked.capacity() * size_of[Bool]()
    bytes += world.storage._spatial_dirty.capacity() * size_of[Entity]()
    bytes += world.storage._spatial_free_blocks.capacity() * size_of[Int]()
    print(
        "MEMORY_AFTER_MOVEMENT" if after_movement else "MEMORY",
        rows,
        distribution,
        Int(partitioned),
        bytes,
        allocations,
        blocks,
        slots,
    )


def main() raises:
    """Warm both layouts and alternate five paired samples for each scenario.

    Raises:
        Error: If any benchmark or complete correctness validation fails.
    """
    for rows in [2048, 32768]:
        for distribution in range(3):
            var group = 16 if distribution == 0 else (
                1024 if distribution == 1 else 1
            )
            var stride = 128 if distribution == 2 else 1
            for mode in range(4):
                var cases = 3 if mode == 0 or mode == 3 else 1
                for scenario in range(cases):
                    var updates = (
                        1 if scenario
                        == 0 else (rows // 64 if scenario == 1 else rows)
                    ) if mode == 0 or mode == 3 else 0
                    var cadence = 4 if mode == 3 and scenario == 1 else 1
                    var reordered = prepare(rows, group, stride, False)
                    var partitioned = prepare(rows, group, stride, True)
                    if mode == 1:
                        memory(reordered, rows, distribution, False)
                        memory(partitioned, rows, distribution, True)
                    for pair in range(6):
                        var a: Float64
                        var b: Float64
                        if pair % 2 == 0:
                            a = sample(
                                reordered,
                                rows,
                                group,
                                stride,
                                updates,
                                mode,
                                cadence,
                            )
                            b = sample(
                                partitioned,
                                rows,
                                group,
                                stride,
                                updates,
                                mode,
                                cadence,
                            )
                        else:
                            b = sample(
                                partitioned,
                                rows,
                                group,
                                stride,
                                updates,
                                mode,
                                cadence,
                            )
                            a = sample(
                                reordered,
                                rows,
                                group,
                                stride,
                                updates,
                                mode,
                                cadence,
                            )
                        validate(
                            reordered,
                            rows,
                            group,
                            stride,
                            updates,
                            16 * (pair + 1),
                        )
                        validate(
                            partitioned,
                            rows,
                            group,
                            stride,
                            updates,
                            16 * (pair + 1),
                        )
                        assert_equal(
                            cell_workload(reordered, rows // group, stride),
                            cell_workload(partitioned, rows // group, stride),
                        )
                        if pair > 0:
                            print(
                                "PAIR",
                                rows,
                                distribution,
                                mode,
                                updates,
                                cadence,
                                pair,
                                a,
                                b,
                            )

                    if mode == 3 and scenario == 2:
                        memory(
                            reordered,
                            rows,
                            distribution,
                            False,
                            after_movement=True,
                        )
                        memory(
                            partitioned,
                            rows,
                            distribution,
                            True,
                            after_movement=True,
                        )
