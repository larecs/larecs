"""Query selection/cursor and CPU/GPU dispatch costs over 64 archetypes.

Build without debug info using --lld-path /usr/bin/ld -I src. Reports seven
warm batches in ns/operation; setup and first GPU compilation are excluded.

Every populated archetype includes Value. Final checks require all 512 rows
and the exact accumulated updates, so missing matches cannot look faster.
Earlier timing samples predate these workload checks and are omitted.

Allocation accounting from ownership paths, not allocator instrumentation:
a nonempty selection cursor copy previously allocated and copied one List
buffer (512 bytes for these 64 indices); it now retains the existing Arc
with zero new selection allocations and no copied indices. Construction now
allocates an Arc owner plus its List buffer. Bounded reservation avoids List
growth for up to 256 candidates on this 64-bit host; sparse queries can
reserve up to two KiB they do not use. Low-level batch cursors share bounded
EntityRange metadata across copies; they are not GPU selection lists.

Mask caching evaluation: not retained. Matching costs one linear scan of
retained archetypes. A cache would require a
mask registry, updates for both archetype creation paths, and either interior
mutation or changes to the ref-self internal selection API. It would also
need independent cache updates after storage/world copies and traversal-time
occupancy checks. Caching populated tables alone is invalid after refill.
These costs and borrow/API changes are outside the cursor ownership refactor.
A cache prototype was not benchmarked, so no claim is made that caching
could not improve query-heavy CPU workloads. Public API redesign remains
separate. Query selections contain store indices, never table pointers.
"""

from std.benchmark import keep
from std.sys import has_accelerator
from std.time import perf_counter_ns
from std.testing import assert_equal
from larecs import ExecutionBackend, World, Filter, KernelContext, SystemContext
from larecs.bitmask import BitMask


@fieldwise_init
struct Value(TrivialRegisterPassable):
    var value: Float32


@fieldwise_init
struct Tag[ID: Int](TrivialRegisterPassable):
    var value: Int32


comptime ManyWorld = World[
    Value, Tag[0], Tag[1], Tag[2], Tag[3], Tag[4], Tag[5]
]
comptime FILTER = Filter().include[Value]()


def increment(context: KernelContext[FILTER]):
    """Updates every selected row.

    Args:
        context: The selected component columns.
    """
    for entity in context:
        entity.get[Value]().value += 1


def populate(mut world: ManyWorld) raises:
    """Creates all 64 tag combinations, each with eight initialized rows.

    Args:
        world: The benchmark world.

    Raises:
        Error: If population fails.
    """
    for combination in range(64):
        var mask = BitMask(0)
        mask.set[True](0)
        for bit in range(6):
            if combination & (1 << bit):
                mask.set[True](bit + 1)
        var idx = world.storage._get_archetype_index_by_mask(mask^)
        _ = world.storage._create_entities(idx, 8)
        ref archetype = world.storage._archetypes[idx]
        archetype.init_component_range[Value](0, 8, Value(0))
        comptime for bit in range(6):
            if combination & (1 << bit):
                archetype.init_component_range[Tag[bit]](0, 8, Tag[bit](0))


def measure[mode: Int](mut world: ManyWorld) raises:
    """Times query creation, cursor copying, and CPU/GPU dispatch.

    Parameters:
        mode: Zero for query construction, one for copying, two for CPU,
            three for GPU dispatch (including transfers and synchronization).

    Args:
        world: The populated benchmark world.

    Raises:
        Error: If querying or dispatch fails.
    """
    comptime iterations = 10000 if mode < 2 else 100
    comptime if mode < 2:
        var query = world.storage.query[FILTER]()
        for batch in range(8):
            var start = perf_counter_ns()
            for _ in range(iterations):
                comptime if mode == 0:
                    keep(world.storage.query[FILTER]())
                else:
                    keep(query.copy())
            var elapsed = perf_counter_ns() - start
            if batch > 0:
                print(mode, Float64(elapsed) / Float64(iterations))
    else:
        var context = SystemContext(world)
        for batch in range(8):
            var start = perf_counter_ns()
            for _ in range(iterations):
                context.run[
                    increment,
                    backend=(
                        ExecutionBackend.DEVICE if mode
                        == 3 else ExecutionBackend.HOST
                    ),
                ]()
            var elapsed = perf_counter_ns() - start
            if batch > 0:
                print(mode, Float64(elapsed) / Float64(iterations))

    var expected = Float32(0)
    comptime if mode >= 2:
        expected = Float32((mode - 1) * 8 * iterations)
    var count = 0
    var checksum = Float32(0)
    for entity in world.storage.query[FILTER]():
        var value = entity.get[Value]().value
        assert_equal(value, expected)
        checksum += value
        count += 1
    assert_equal(count, 512)
    assert_equal(checksum, expected * 512)
    keep(checksum)


def main() raises:
    """Runs host modes and the supported device mode on one initialized world.

    Raises:
        Error: If setup or a benchmark operation fails.
    """
    var world = ManyWorld()
    populate(world)
    comptime for mode in range(4):
        comptime if mode < 3 or has_accelerator():
            measure[mode](world)
