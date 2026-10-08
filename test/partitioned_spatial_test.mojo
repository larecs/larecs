"""Cluster-local storage, identity repair, exact membership, and reclamation."""

from std.testing import (
    assert_equal,
    assert_true,
    assert_false,
    assert_raises,
    TestSuite,
)
from larecs import (
    World,
    Entity,
    Filter,
    SpatialClassifier,
    SystemContext,
    KernelContext,
    Components,
)
from larecs.entity import EntityAccessor
from larecs.spatial import _PartitionId


@fieldwise_init
struct Heap(Copyable, Movable):
    """Heap-owned row payload whose values must survive every transfer."""

    var values: List[Int]


@fieldwise_init
struct Tag(Copyable, Movable):
    """Component distinguishing two logical archetypes."""

    var value: Int


@fieldwise_init
struct Policy(SpatialClassifier):
    """Classify by integer input; negative inputs exercise failure recovery."""

    comptime Accessor = EntityAccessor[Filter().read[Int]()]

    def classify(self, entity: Self.Accessor) raises -> UInt64:
        """Return the exact nonnegative input key.

        Args:
            entity: Read-only input row.

        Raises:
            Error: If the input is negative.

        Returns:
            The entity's cluster identity.
        """
        var key = entity.get[Int]()
        if key < 0:
            raise Error("negative cluster")
        return UInt64(key)


comptime TestWorld = World[Int, Heap, Tag]


def prepare() raises -> TestWorld:
    """Build two logical archetypes with several blocks per cluster.

    Raises:
        Error: If setup or maintenance fails.

    Returns:
        A partitioned world with stable identity payloads.
    """
    var world = TestWorld()
    for i in range(65):
        if i % 2:
            _ = world.storage.add_entity(i % 3, Heap([i + 1]), Tag(1))
        else:
            _ = world.storage.add_entity(i % 3, Heap([i + 1]))
    world.register_spatial_classifier[Filter().read[Int]()](
        Policy(), partitioned=True, block_capacity=8
    )
    world.maintain_spatial()
    return world^


def validate(mut world: TestWorld) raises:
    """Check unique query membership, bounded homogeneous blocks, and locations.

    Args:
        world: Maintained world with identity-valued payloads.

    Raises:
        Error: If any invariant fails.
    """
    var seen = Dict[Entity, Bool]()
    for row in world.storage.query[Filter().read[Int, Heap]()]():
        var entity = row.get_entity()
        assert_false(entity in seen)
        seen[entity] = True
        assert_equal(row.get[Heap]().values[0], Int(entity.get_id()))
        var location = world.storage._entity_locations[entity.get_id()]
        ref block = world.storage._archetypes[location.archetype_index]
        assert_equal(block.get_entity(location.entity_index), entity)
        assert_true(Bool(block._partition_key))
        assert_equal(block._partition_key.value(), UInt64(row.get[Int]()))
        assert_true(len(block) <= 8)
        assert_true(block._storage._capacity <= 8)
        assert_true(block._entities.capacity() <= 8)
        assert_true(block.get_node_index() >= 0)
        var staging = world.storage._archetype_map[block.get_node_index()]
        assert_equal(
            world.storage._archetypes[staging].get_mask(), block.get_mask()
        )
        assert_false(Bool(world.storage._archetypes[staging]._partition_key))
    assert_equal(len(seen), len(world))
    var counts = Dict[_PartitionId, Int]()
    for block in world.storage._archetypes:
        if block._partition_key:
            var key = _PartitionId(
                block.get_node_index(), block._partition_key.value()
            )
            if key not in counts:
                counts[key] = 0
            if len(block) < 8:
                counts[key] += 1
            assert_true(counts[key] <= 1)
            assert_true(len(block) > 0)


def bump(context: KernelContext[Filter().include[Tag]()]):
    """Increment each matching selected row once.

    Args:
        context: CPU or packed GPU row context.
    """
    for row in context:
        row.get[Tag]().value += 1


def test_blocks_reclassification_compaction_reuse_and_copy() raises:
    """Dirty transfers preserve heap payloads, and empty slots are reclaimed.

    Raises:
        Error: If a mutation or invariant fails.
    """
    var world = prepare()
    validate(world)
    var initial_slots = len(world.storage._archetypes)
    for i in range(1, 66):
        world.storage.set(Entity(i), 7)
    world.maintain_spatial()
    validate(world)
    for frame in range(5):
        for i in range(1, 66):
            world.storage.set(Entity(i), 8 + frame % 2)
        world.maintain_spatial()
        validate(world)
        assert_true(len(world.storage._archetypes) <= initial_slots + 10)
    var copied = world.copy()
    copied.storage.set(Entity(1), 100)
    copied.maintain_spatial()
    validate(copied)
    validate(world)
    assert_equal(world.storage._spatial_keys[1], UInt64(8))
    for i in range(1, 66):
        world.storage.remove_entity(Entity(i))
    world.maintain_spatial()
    assert_equal(len(world), 0)
    for block in world.storage._archetypes:
        assert_false(Bool(block._partition_key))
        assert_equal(block._storage._capacity, 0)


def test_cluster_selection_exact_chains_locks_and_existing_destination() raises:
    """Cluster selections span blocks and never include preexisting destination rows.

    Raises:
        Error: If selection semantics or locks fail.
    """
    var world = prepare()
    var context = SystemContext(world)
    var selected = context.select_cluster(UInt64(1))
    assert_equal(len(selected), 22)
    with assert_raises():
        context.world[].maintain_spatial()
    var query = context.world[].storage.query[Filter().read[Int]()]()
    with assert_raises():
        selected.remove[Tag, filter=Filter().include[Tag]()]()
    _ = query^
    selected.add[Tag, filter=Filter().exclude[Tag]()](Tag(10))
    assert_equal(len(selected), 11)
    selected.run[bump]()
    selected.replace[remove=Components[Tag]()](Tag(20))
    selected.run[bump]()
    selected^.release()
    for row in context.world[].storage.query[Filter().read[Int, Tag]()]():
        var id = Int(row.get_entity().get_id())
        var expected = 21 if id % 2 == 1 and (id - 1) % 3 == 1 else 1
        assert_equal(row.get[Tag]().value, expected)
    with assert_raises(contains="clean"):
        var pending = context.select_cluster(UInt64(1))
    context.world[].maintain_spatial()
    validate(context.world[])
    var empty = context.select_cluster(UInt64(999))
    assert_equal(len(empty), 0)
    empty^.release()


def test_low_level_bulk_and_same_mask_replacement() raises:
    """Bulk mutations move all source blocks once and preserve iterator membership.

    Raises:
        Error: If bulk transfers or component lifetimes fail.
    """
    var world = prepare()
    world.storage.replace[Tag]().by(Tag(9), entity=Entity(2))
    var changed = world.storage.add[Tag, filter=Filter().exclude[Tag]()](Tag(5))
    assert_equal(len(changed), 33)
    var seen = Dict[Entity, Bool]()
    for row in changed^:
        var entity = row.get_entity()
        assert_false(entity in seen)
        seen[entity] = True
    assert_equal(len(seen), 33)
    world.maintain_spatial()
    validate(world)
    var replaced = world.storage.replace[Tag]().by[
        Tag, filter=Filter().include[Tag]()
    ](Tag(6))
    assert_equal(len(replaced), 65)
    _ = replaced^
    var removed = world.storage.remove[Tag, filter=Filter().include[Tag]()]()
    assert_equal(len(removed), 65)
    _ = removed^
    world.maintain_spatial()
    validate(world)


def test_classification_failure_preserves_placement_and_retry() raises:
    """Failed classification moves nothing and retains all dirty marks for retry.

    Raises:
        Error: If failure atomicity or retry fails.
    """
    var world = prepare()
    var locations = world.storage._entity_locations.copy()
    world.storage.set(Entity(1), 99)
    world.storage.set(Entity(65), -1)
    with assert_raises(contains="negative cluster"):
        world.maintain_spatial()
    for i in range(1, 66):
        assert_equal(
            world.storage._entity_locations[i].entity_index,
            locations[i].entity_index,
        )
        assert_equal(
            world.storage._entity_locations[i].archetype_index,
            locations[i].archetype_index,
        )
    world.storage.set(Entity(65), 99)
    world.maintain_spatial()
    validate(world)
    assert_equal(world.storage._spatial_keys[1], UInt64(99))
    assert_equal(world.storage._spatial_keys[65], UInt64(99))


def test_registration_validation_and_unclassified_rows() raises:
    """Invalid capacities leave registration usable and unmatched rows unpartitioned.

    Raises:
        Error: If registration or eligibility invariants fail.
    """
    var world = TestWorld()
    for capacity in [0, -1, 3]:
        with assert_raises(contains="power of two"):
            world.register_spatial_classifier[Filter().read[Int]()](
                Policy(), partitioned=True, block_capacity=capacity
            )
    var unrelated = world.storage.add_entity(Heap([1]))
    _ = world.storage.add_entity(1, Heap([2]))
    world.register_spatial_classifier[Filter().read[Int]()](
        Policy(), partitioned=True, block_capacity=1
    )
    world.maintain_spatial()
    var location = world.storage._entity_locations[unrelated.get_id()]
    assert_false(
        Bool(world.storage._archetypes[location.archetype_index]._partition_key)
    )
    assert_equal(world.storage.get[Heap](unrelated).values[0], 1)
    var context = SystemContext(world)
    var selection = context.select_cluster(UInt64(1))
    assert_equal(len(selection), 1)
    selection^.release()


def test_partition_lifetimes_without_copy_or_early_destruction() raises:
    """Typed transfers and compaction do not copy or destroy retained components.

    Raises:
        Error: If component lifecycle counts fail.
    """
    from host_storage_lifecycle_test import LifecycleCounters
    from host_storage_lifecycle_test import TrackedComponent

    var counters = LifecycleCounters()
    var world = World[Int, TrackedComponent]()
    for i in range(25):
        _ = world.storage.add_entity(i % 3, counters.component())
    world.register_spatial_classifier[Filter().read[Int]()](
        Policy(), partitioned=True, block_capacity=8
    )
    var copies = counters.copy_counter()
    var deletes = counters.del_counter()
    world.maintain_spatial()
    assert_equal(counters.copy_counter(), copies)
    assert_equal(counters.del_counter(), deletes)
    var moves = counters.move_counter()
    world.maintain_spatial()
    assert_equal(counters.move_counter(), moves)
    for i in range(1, 26):
        world.storage.set(Entity(i), 7)
    world.maintain_spatial()
    assert_equal(counters.copy_counter(), copies)
    assert_equal(counters.del_counter(), deletes)
    for i in range(1, 26):
        world.storage.remove_entity(Entity(i))
    world.maintain_spatial()
    assert_equal(counters.del_counter() - deletes, 25)
    _ = world^
    assert_equal(counters.del_counter() - deletes, 25)


def test_query_copy_cursors_and_cpu_closure_across_blocks() raises:
    """Copied queries retain independent cursors/locks and CPU closures visit all rows.

    Raises:
        Error: If cursor, lock, or execution membership checks fail.
    """
    var world = prepare()
    var query = world.storage.query[Filter().read[Int, Heap]()]()
    var first = query.__next__().get_entity()
    var copied = query.copy()
    var remaining = List[Entity]()
    for row in query^:
        remaining.append(row.get_entity())
    assert_equal(len(remaining), 64)
    assert_true(world.storage.is_locked())
    with assert_raises():
        world.maintain_spatial()
    var index = 0
    for row in copied^:
        assert_equal(row.get_entity(), remaining[index])
        assert_true(row.get_entity() != first)
        index += 1
    assert_equal(index, 64)
    assert_false(world.storage.is_locked())
    var visits = 0

    def count(rows: KernelContext[Filter().read[Int, Heap]()]) {mut}:
        """Count the rows in one physical CPU range.

        Args:
            rows: Read-only block rows.
        """
        for _ in rows:
            visits += 1

    var context = SystemContext(world)
    context.run(count)
    assert_equal(visits, 65)
    assert_equal(len(context.world[].storage._spatial_dirty), 0)


def test_mask_lookup_after_recycling_and_new_logical_transition() raises:
    """Exact masks resolve canonical graph stores even when blocks reuse earlier slots.

    Raises:
        Error: If mask lookup or new logical transitions lose their identities.
    """
    var world = prepare()
    for id in range(1, 66):
        world.storage.set(Entity(id), 7)
    world.maintain_spatial()
    world.storage.remove[Heap](Entity(1))
    world.maintain_spatial()
    var location = world.storage._entity_locations[1]
    var node = world.storage._archetypes[
        location.archetype_index
    ].get_node_index()
    var mask = (
        world.storage._archetypes[location.archetype_index].get_mask().copy()
    )
    var staging = world.storage._get_archetype_index_by_mask(mask^)
    assert_equal(staging, world.storage._archetype_map[node])
    assert_equal(
        len(
            world.storage._archetypes[staging]._storage.get_component_span[
                Int
            ]()
        ),
        0,
    )
    assert_false(Bool(world.storage._archetypes[staging]._partition_key))
    world.storage.add(Entity(1), Heap([1]))
    world.maintain_spatial()
    validate(world)


def main() raises:
    """Run partition invariants and integration tests.

    Raises:
        Error: If a test fails.
    """
    TestSuite.discover_tests[__functions_in_module()]().run()
