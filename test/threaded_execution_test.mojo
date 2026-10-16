"""Exact threaded membership, fallback, resources, preparation, and concurrency."""

from std.testing import (
    assert_equal,
    assert_true,
    assert_false,
    assert_raises,
    TestSuite,
)
from std.ffi import external_call
from std.time import perf_counter_ns
from larecs import (
    World,
    SystemContext,
    KernelContext,
    Filter,
    Resources,
    ResourceType,
    Entity,
    EntityRange,
    ThreadedExecutionConfig,
    SpatialClassifier,
    DevicePassableResource,
    ResourceAdapter,
    ResourceDeviceCache,
)
from larecs.entity import EntityAccessor


@fieldwise_init
struct Observation(Copyable, Movable):
    """Per-row values expose chunk-local indices and invocation lengths."""

    var value: Int32
    var local: Int32
    var length: Int32


@fieldwise_init
struct Heap(Copyable, Movable):
    """Unaccessed owning components must not prohibit threading."""

    var values: List[Int32]


@fieldwise_init
struct Step(ResourceType):
    """Small ordinary read-only resource."""

    var value: Int32


@fieldwise_init
struct SamplesView(TrivialRegisterPassable):
    """Immutable pointer to host-owned samples shared across all jobs."""

    var samples: Pointer[Int32, ImmUntrackedOrigin]


@fieldwise_init
struct Samples(DevicePassableResource):
    """Instrumented source, with caller-only binding diagnostics."""

    comptime KernelView = SamplesView
    comptime Adapter = SamplesAdapter
    var values: List[Int32]
    var binds: Pointer[Int, MutUntrackedOrigin]
    var fail: Bool


struct SamplesAdapter(ResourceAdapter):
    """Binds once on the caller; workers only read immutable sample memory."""

    comptime Source = Samples
    comptime View = SamplesView

    @staticmethod
    def validate(source: Self.Source) raises:
        """Requires one sample before any descriptor is prepared.

        Args:
            source: Current owning source.

        Raises:
            Error: If sample storage is empty.
        """
        if len(source.values) == 0:
            raise Error("missing sample")

    @staticmethod
    def bind_host(source: Self.Source) raises -> Self.View:
        """Records caller preparation and borrows stable samples.

        Args:
            source: Leased sample owner and preparation diagnostics.

        Raises:
            Error: If the source requests a preparation failure.

        Returns:
            Shared read-only sample descriptor.
        """
        source.binds[] += 1
        if source.fail:
            raise Error("injected host binding failure")
        return {
            Pointer[Int32, ImmUntrackedOrigin](
                unsafe_from_address=Int(source.values.unsafe_ptr())
            )
        }

    @staticmethod
    def prepare_device(
        source: Self.Source, mut cache: ResourceDeviceCache
    ) raises -> Self.View:
        """Rejects device preparation in this host-only test adapter.

        Args:
            source: Current source.
            cache: Device allocation cache.

        Raises:
            Error: Always, because this test has no device implementation.

        Returns:
            No descriptor is produced.
        """
        raise Error("host-only test adapter")


comptime access = Filter().include[Observation]().exclude[Float32]()
comptime reads = Resources().read[Step, Samples]()


def observe(rows: KernelContext[access, reads]):
    """Records local chunk boundaries while updating each eligible row.

    Args:
        rows: Exact disjoint range and shared read-only bindings.
    """
    var increment = (
        rows.resources.get[Step]().value
        + rows.resources.get[Samples]().samples[]
    )
    var local = Int32(0)
    for row in rows:
        ref value = row.get[Observation]()
        value.value += increment
        value.local = local
        value.length = rows.length
        local += 1


def _check_ranges[
    selected: Bool, threaded: Bool
](workers: Int, cutoff: Int) raises:
    """Checks once-only writes, filters, tails, and chunk/fallback granularity.

    Parameters:
        selected: Execute disjoint saved ranges with unselected gaps.
        threaded: Explicitly select the new engine or the sequential control.

    Args:
        workers: Configured worker-task budget.
        cutoff: Configured matched-row cutoff.

    Raises:
        Error: If setup or exact per-row validation fails.
    """
    var config = ThreadedExecutionConfig(
        workers=workers, min_parallel_rows=cutoff
    )
    var world = World[Observation, Float32, Heap](execution_config=config)
    var binds = 0
    world.resources.add(Step(2))
    world.resources.add(
        Samples(
            [Int32(3)],
            Pointer[Int, MutUntrackedOrigin](
                unsafe_from_address=Int(Pointer(to=binds))
            ),
            False,
        )
    )
    var entities = List[Entity]()
    for i in range(67):
        entities.append(world.storage.add_entity(Observation(Int32(i), -1, -1)))
    for i in range(5):
        entities.append(
            world.storage.add_entity(
                Observation(Int32(i + 67), -1, -1), Heap([Int32(i)])
            )
        )
    var excluded = world.storage.add_entity(
        Observation(999, -1, -1), Float32(0)
    )
    var context = SystemContext(world)
    var total = 72
    comptime if selected:
        total = 20
        var selection = context._empty_selection()
        var index = world.storage._entity_locations[
            entities[0].get_id()
        ].archetype_index
        selection._ranges.append(EntityRange(index, 3, 17))
        selection._ranges.append(EntityRange(index, 31, 3))
        selection._ranges.append(EntityRange(index, 0, 0))
        for _ in range(2):
            selection.run[observe, threaded=threaded]()
        assert_true(selection._is_world_locked())
        selection^.release()
    else:
        for _ in range(2):
            context.run[observe, threaded=threaded]()
    assert_equal(binds, 2)
    assert_false(world.storage.is_locked())
    assert_false(world._execution_active)
    var parallel = threaded and workers > 1 and total >= cutoff
    var chunk = max(1, total // (workers * 4) + Int(total % (workers * 4) != 0))
    for i in range(72):
        var eligible = True
        var first = 0 if i < 67 else 67
        var count = 67 if i < 67 else 5
        comptime if selected:
            eligible = (i >= 3 and i < 20) or (i >= 31 and i < 34)
            first = 3 if i < 20 else 31
            count = 17 if i < 20 else 3
        ref value = world.storage.get[Observation](entities[i])
        assert_equal(value.value, Int32(i + (10 if eligible else 0)))
        if eligible:
            var local = i - first
            var length = count
            if parallel:
                length = min(chunk, count - (local // chunk) * chunk)
                local = local % chunk
            assert_equal(value.local, Int32(local))
            assert_equal(value.length, Int32(length))
        else:
            assert_equal(value.local, -1)
    assert_equal(world.storage.get[Observation](excluded).value, 999)
    assert_equal(world.resources.get[Samples]().values[0], 3)
    var copied = world.copy()
    var moved = copied^
    assert_equal(moved.execution_config().workers(), workers)
    assert_equal(moved.execution_config().min_parallel_rows(), cutoff)


def test_ranges_resources_and_fallback() raises:
    """Checks exact selections and ordinary dispatch at 1/2/4 worker tasks.

    Raises:
        Error: If threaded or sequential range semantics differ from the contract.
    """
    for workers in [1, 2, 4]:
        for cutoff in [0, 1000]:
            _check_ranges[False, True](workers, cutoff)
            _check_ranges[True, True](workers, cutoff)
        _check_ranges[False, False](workers, 0)
        _check_ranges[True, False](workers, 0)


def test_invalid_settings() raises:
    """Rejects invalid bounds and multiplication overflow.

    Raises:
        Error: If any invalid configuration is accepted.
    """
    for workers in [0, -1]:
        with assert_raises():
            _ = ThreadedExecutionConfig(workers=workers)
    with assert_raises():
        _ = ThreadedExecutionConfig(workers=2, chunks_per_worker=0)
    with assert_raises():
        _ = ThreadedExecutionConfig(workers=2, min_parallel_rows=-1)
    with assert_raises():
        _ = ThreadedExecutionConfig(workers=Int(Int64.MAX), chunks_per_worker=2)
    assert_equal(ThreadedExecutionConfig().workers(), 1)


def test_preparation_failure_and_empty_validation() raises:
    """Missing sources and failed binding leave rows untouched and guards released.

    Raises:
        Error: If preparation executes rows, skips validation, or leaks a guard.
    """
    var world = World[Observation, Float32](
        execution_config=ThreadedExecutionConfig(workers=4, min_parallel_rows=0)
    )
    var context = SystemContext(world)
    with assert_raises():
        context.run[observe, threaded=True]()
    var entity = world.storage.add_entity(Observation(7, -1, -1))
    var binds = 0
    world.resources.add(Step(2))
    world.resources.add(
        Samples(
            [Int32(3)],
            Pointer[Int, MutUntrackedOrigin](
                unsafe_from_address=Int(Pointer(to=binds))
            ),
            True,
        )
    )
    with assert_raises():
        context.run[observe, threaded=True]()
    assert_equal(world.storage.get[Observation](entity).value, 7)
    assert_false(world.storage.is_locked())
    assert_false(world._execution_active)
    world.resources.get[Samples]().fail = False
    context.run[observe, threaded=True]()
    assert_equal(world.storage.get[Observation](entity).value, 12)


def empty_kernel(rows: KernelContext[Filter().include[Int32]()]):
    """Fails if an empty match incorrectly invokes a kernel.

    Args:
        rows: Invalid empty invocation that must never be constructed.
    """
    from std.os import abort

    abort("Empty matches must not invoke kernels")


def test_empty_matches_and_single_job() raises:
    """Handles zero jobs and clamps a large worker budget to a single job.

    Raises:
        Error: If empty execution invokes a kernel or a single row is missed.
    """
    var world = World[Int32](
        execution_config=ThreadedExecutionConfig(
            workers=128, min_parallel_rows=0
        )
    )
    var context = SystemContext(world)
    context.run[empty_kernel, threaded=True]()
    var selection = context._empty_selection()
    selection.run[empty_kernel, threaded=True]()
    selection^.release()
    var entity = world.storage.add_entity(Int32(4))
    context.run[increment, threaded=True]()
    assert_equal(world.storage.get[Int32](entity), 5)


def test_range_preparation_is_transactional() raises:
    """Invalid or overlapping ranges cannot partially execute valid rows.

    Raises:
        Error: If preparation partially executes or retains invocation guards.
    """
    var world = World[Int32](
        execution_config=ThreadedExecutionConfig(workers=4, min_parallel_rows=0)
    )
    var entity = world.storage.add_entity(Int32(7))
    var context = SystemContext(world)
    var selection = context._empty_selection()
    var index = world.storage._entity_locations[entity.get_id()].archetype_index
    selection._ranges.append(EntityRange(index, 0, 1))
    selection._ranges.append(EntityRange(index, 1, 1))
    with assert_raises():
        selection.run[increment, threaded=True]()
    assert_equal(world.storage.get[Int32](entity), 7)
    selection._ranges[1] = EntityRange(index, 0, 1)
    with assert_raises():
        selection.run[increment, threaded=True]()
    assert_equal(world.storage.get[Int32](entity), 7)
    assert_false(world._execution_active)
    selection^.release()
    assert_false(world.storage.is_locked())


@fieldwise_init
struct Policy(SpatialClassifier):
    """Groups rows by their integer component modulo three."""

    comptime Accessor = EntityAccessor[Filter().read[Int32]()]

    def classify(self, row: Self.Accessor) raises -> UInt64:
        """Returns a bounded cluster key.

        Args:
            row: Read-only classifier inputs.

        Returns:
            Input modulo three.
        """
        return UInt64(row.get[Int32]() % 3)


def increment(rows: KernelContext[Filter().include[Int32]()]):
    """Updates classifier input to exercise caller-side spatial invalidation.

    Args:
        rows: One disjoint prepared range.
    """
    for row in rows:
        row.get[Int32]() += 1


def test_partition_staging_and_cluster_selection() raises:
    """Visits partition/staging rows once, repairs keys, and respects exact clusters.

    Raises:
        Error: If spatial maintenance, membership, or row values are incorrect.
    """
    var world = World[Int32](
        execution_config=ThreadedExecutionConfig(workers=4, min_parallel_rows=0)
    )
    var entities = List[Entity]()
    for i in range(97):
        entities.append(world.storage.add_entity(Int32(i)))
    world.register_spatial_classifier[Filter().read[Int32]()](
        Policy(), partitioned=True
    )
    world.maintain_spatial()
    entities.append(world.storage.add_entity(Int32(97)))
    var context = SystemContext(world)
    context.run[increment, threaded=True]()
    for i in range(98):
        assert_equal(world.storage.get[Int32](entities[i]), Int32(i + 1))
    world.maintain_spatial()
    var selection = context.select_cluster(UInt64(1))
    selection.run[increment, threaded=True]()
    selection^.release()
    for i in range(98):
        assert_equal(
            world.storage.get[Int32](entities[i]),
            Int32(i + 1 + Int((i + 1) % 3 == 1)),
        )
    world.maintain_spatial()


@fieldwise_init
struct Interval(Copyable, Movable):
    """One chunk's thread identity and measured execution interval."""

    var thread: UInt64
    var start: Int
    var end: Int


def overlap_kernel(rows: KernelContext[Filter().include[Interval]()]):
    """Records overlapping execution without mutable shared bindings or a barrier.

    Args:
        rows: Disjoint row receiving this invocation's timing diagnostics.
    """
    var thread = external_call["pthread_self", UInt64]()
    var start = Int(perf_counter_ns())
    while Int(perf_counter_ns()) - start < 5_000_000:
        pass
    var end = Int(perf_counter_ns())
    for row in rows:
        row.set(Interval(thread, start, end))


def test_actual_concurrency() raises:
    """Requires overlapping intervals on distinct runtime threads.

    Raises:
        Error: If the runtime executes all jobs serially.
    """
    var world = World[Interval](
        execution_config=ThreadedExecutionConfig(
            workers=4, chunks_per_worker=1, min_parallel_rows=0
        )
    )
    _ = world.storage.add_entities(Interval(0, 0, 0), count=4)
    var context = SystemContext(world)
    var overlap = False
    for _ in range(3):
        context.run[overlap_kernel, threaded=True]()
        var intervals = List[Interval]()
        for row in world.storage.query[Filter().read[Interval]()]():
            intervals.append(row.get[Interval]().copy())
        for i in range(4):
            for j in range(i):
                if intervals[i].thread != intervals[j].thread and max(
                    intervals[i].start, intervals[j].start
                ) < min(intervals[i].end, intervals[j].end):
                    overlap = True
    assert_true(overlap)


comptime functions = __functions_in_module()


def main() raises:
    """Runs threaded host contract checks.

    Raises:
        Error: If any contract check fails.
    """
    TestSuite.discover_tests[functions]().run()
