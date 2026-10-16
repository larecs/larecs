# SKIP_ASAN
# SKIP_DEBUG

from std.sys import has_accelerator, size_of
from std.testing import *

from larecs import (
    EntityRange,
    World,
    Entity,
    Filter,
    SpatialClassifier,
    SystemContext,
    KernelContext,
)
from larecs.entity import EntityAccessor
from larecs.component import ComponentType

comptime TestWorld = World[Int32, Float32]
comptime rows = 6


def accumulate(
    context: KernelContext[Filter().include[Int32]().read[Float32]()],
):
    """Adds each row's float to its integer.

    Args:
        context: Rows with a mutable integer and a read-only float.
    """
    for entity in context:
        entity.get[Int32]() += Int32(entity.get[Float32]())


def write_floats(context: KernelContext[Filter().write[Float32]()]):
    """Overwrites every float with 3 on the host.

    Args:
        context: Rows with a write-only float.
    """
    for entity in context:
        entity.set(Float32(3))


def read_floats(context: KernelContext[Filter().read[Float32]()]):
    """Reads floats without writing anything.

    Args:
        context: Rows with a read-only float.
    """
    for entity in context:
        _ = entity.get[Float32]()


def read_float_only_rows(
    context: KernelContext[Filter().read[Float32]().exclude[Int32]()],
):
    """Reads floats of rows without an integer.

    Args:
        context: Float-only rows.
    """
    for entity in context:
        _ = entity.get[Float32]()


def _world() raises -> TestWorld:
    """Creates one store with integers 0 and floats 1.

    Raises:
        Error: If adding entities fails.

    Returns:
        The world, with device copy reuse still disabled.
    """
    var world = TestWorld()
    for _ in range(rows):
        _ = world.storage.add_entity(Int32(0), Float32(1))
    return world^


def _store(mut world: TestWorld) -> Int:
    """Returns the store index of the first entity.

    Args:
        world: World to inspect.

    Returns:
        The physical store index.
    """
    return world.storage._entity_locations[1].archetype_index


def _revision[T: ComponentType](mut world: TestWorld) -> UInt64:
    """Returns the column revision of `T` in the first entity's store.

    Parameters:
        T: Component type.

    Args:
        world: World to inspect.

    Returns:
        The column revision.
    """
    comptime id = TestWorld.HostStorage.component_manager.get_id[T]()
    return world.storage._archetypes[_store(world)]._storage._column_revision(
        id
    )


def _check_ints(mut world: TestWorld, expected: Int32) raises:
    """Checks every integer.

    Args:
        world: World to inspect.
        expected: Required value.

    Raises:
        Error: If any row differs.
    """
    for entity in world.storage.query[Filter().read[Int32]()]():
        assert_equal(entity.get[Int32](), expected)


def _run(mut world: TestWorld) raises -> Int:
    """Runs `accumulate` on the device.

    Args:
        world: World to run on.

    Raises:
        Error: If execution fails.

    Returns:
        Bytes uploaded by the invocation.
    """
    var context = SystemContext(world)
    context.run[accumulate, on_device=True]()
    return world._last_device_upload.bytes


def test_column_revisions_advance_on_mutating_access() raises:
    """Checks host operations that must or must not advance column revisions.

    Raises:
        Error: If a revision changes unexpectedly or fails to advance.
    """
    var world = _world()
    var ints = _revision[Int32](world)
    var floats = _revision[Float32](world)

    assert_equal(world.storage.read[Float32](Entity(1)), 1)
    for _ in world.storage.query[Filter().read[Int32, Float32]()]():
        pass
    assert_equal(_revision[Int32](world), ints)
    assert_equal(_revision[Float32](world), floats)

    _ = world.storage.get[Int32](Entity(1))
    assert_true(_revision[Int32](world) > ints)
    assert_equal(_revision[Float32](world), floats)
    ints = _revision[Int32](world)

    world.storage.set(Entity(1), Float32(2))
    assert_true(_revision[Float32](world) > floats)
    assert_equal(_revision[Int32](world), ints)
    floats = _revision[Float32](world)

    var context = SystemContext(world)
    context.run[read_floats]()
    assert_equal(_revision[Float32](world), floats)
    context.run[write_floats]()
    assert_true(_revision[Float32](world) > floats)
    assert_equal(_revision[Int32](world), ints)
    floats = _revision[Float32](world)
    context.run[write_floats, threaded=True]()
    assert_true(_revision[Float32](world) > floats)
    floats = _revision[Float32](world)

    _ = world.storage.add_entity(Int32(0), Float32(1))
    assert_true(_revision[Int32](world) > ints)
    assert_true(_revision[Float32](world) > floats)
    ints = _revision[Int32](world)
    world.storage.remove_entity(Entity(2))
    assert_true(_revision[Int32](world) > ints)


def test_world_copies_get_fresh_store_incarnations() raises:
    """Gives every copied store a fresh nonzero incarnation.

    Raises:
        Error: If a copy shares a store identity with its source.
    """
    var world = _world()
    _ = world.storage.add_entity(Int32(0))
    var copied = world.copy()
    for index in range(len(world.storage._archetypes)):
        var original = world.storage._archetypes[index]._storage._incarnation
        assert_true(original != 0)
        assert_true(
            copied.storage._archetypes[index]._storage._incarnation != original
        )


@fieldwise_init
struct Policy(SpatialClassifier):
    """Classifies rows by their integer."""

    comptime Accessor = EntityAccessor[Filter().read[Int32]()]

    def classify(self, entity: Self.Accessor) raises -> UInt64:
        """Returns the integer as cluster key.

        Args:
            entity: Read-only input row.

        Raises:
            Error: Never.

        Returns:
            The cluster key.
        """
        return UInt64(entity.get[Int32]())


def _incarnations(world: TestWorld) -> Dict[UInt64, Tuple[Int, UInt64]]:
    """Maps each live cluster key to its store index and incarnation.

    Args:
        world: Partitioned world.

    Returns:
        Store index and incarnation per partition key.
    """
    var result = Dict[UInt64, Tuple[Int, UInt64]]()
    for index in range(len(world.storage._archetypes)):
        ref store = world.storage._archetypes[index]
        if store._partition_key and len(store) > 0:
            result[store._partition_key.value()] = (
                index,
                store._storage._incarnation,
            )
    return result^


def test_store_identity_across_moves_and_reclamation() raises:
    """Keeps live store identities stable; reused indices get new identities.

    Raises:
        Error: If a live store changes identity or a reused index keeps one.
    """
    var world = TestWorld()
    for i in range(9):
        _ = world.storage.add_entity(Int32(i % 3), Float32(1))
    world.register_spatial_classifier[Filter().read[Int32]()](
        Policy(), partitioned=True
    )
    world.maintain_spatial()
    var before = _incarnations(world)
    assert_equal(len(before), 3)

    # Structural changes and partition moves keep live stores in place.
    _ = world.storage.add_entity(Int32(0), Float32(1))
    for i in range(1, 10):
        if world.storage.read[Int32](Entity(i)) == 2:
            world.storage.set(Entity(i), Int32(5))
    world.maintain_spatial()
    var moved = _incarnations(world)
    for key in [UInt64(0), UInt64(1)]:
        assert_equal(moved[key][0], before[key][0])
        assert_equal(moved[key][1], before[key][1])
    assert_false(UInt64(2) in moved)
    var reclaimed = before[UInt64(2)][0]
    assert_true(moved[UInt64(5)][0] != reclaimed)

    # The next new cluster reuses the reclaimed index with a new identity.
    for i in range(1, 10):
        if world.storage.read[Int32](Entity(i)) == 5:
            world.storage.set(Entity(i), Int32(6))
    world.maintain_spatial()
    var reused = _incarnations(world)
    var found = False
    for entry in reused.items():
        if entry.value[0] == reclaimed:
            found = True
            assert_equal(entry.key, UInt64(6))
            assert_true(entry.value[1] != before[UInt64(2)][1])
    assert_true(found)


def test_unchanged_columns_skip_uploads() raises:
    """Uploads read columns once, including the column the kernel wrote.

    Raises:
        Error: If an unchanged column is uploaded again or results differ.
    """
    comptime if has_accelerator():
        var world = _world()
        world.reuse_device_copies(True)
        comptime full = rows * (size_of[Int32]() + size_of[Float32]())
        assert_equal(_run(world), full)
        for i in range(12):
            assert_equal(_run(world), 0)
            _check_ints(world, Int32(i + 2))
        assert_equal(world.storage.read[Float32](Entity(1)), 1)
        assert_equal(_run(world), 0)


def test_disabled_column_transfers_unchanged() raises:
    """Uploads every read column on every run while reuse is disabled.

    Raises:
        Error: If a disabled world skips an upload.
    """
    comptime if has_accelerator():
        var world = _world()
        comptime full = rows * (size_of[Int32]() + size_of[Float32]())
        for _ in range(3):
            assert_equal(_run(world), full)
            assert_equal(world._last_device_upload.segments, 2)


def _mutate[path: Int](mut world: TestWorld) raises -> Int32:
    """Applies one column-revision-advancing operation.

    Parameters:
        path: Mutation path index.

    Args:
        world: World after two `accumulate` runs (integers are 2).

    Raises:
        Error: If the mutation fails.

    Returns:
        The integer every row must hold after the next `accumulate` run.
    """
    comptime if path == 0:
        for i in range(1, rows + 1):
            world.storage.get[Float32](Entity(i)) = 5
        return 7
    elif path == 1:
        for i in range(1, rows + 1):
            world.storage.set(Entity(i), Float32(5))
        return 7
    elif path == 2:
        for i in range(1, rows + 1):
            world.storage.get[Int32](Entity(i)) = 10
        return 11
    elif path == 3:
        var context = SystemContext(world)
        context.run[write_floats]()
        return 5
    elif path == 4:
        var context = SystemContext(world)
        context.run[write_floats, threaded=True]()
        return 5
    elif path == 5:
        # Swap-removal moves the last row into the first row's position.
        world.storage.set(Entity(rows), Int32(2), Float32(4))
        world.storage.remove_entity(Entity(1))
        return 3
    else:
        _ = world.storage.add_entity(Int32(2), Float32(1))
        return 3


def _check_stale_path[path: Int]() raises:
    """Checks that one mutation path refreshes the next device run.

    Parameters:
        path: Mutation path index.

    Raises:
        Error: If the device run reads a stale copy.
    """
    var world = _world()
    world.reuse_device_copies(True)
    _ = _run(world)
    _ = _run(world)
    var expected = _mutate[path](world)
    comptime if path == 5:
        # The moved row kept its float 4, so it accumulates differently.
        assert_true(_run(world) > 0)
        assert_equal(world.storage.read[Int32](Entity(rows)), 6)
        return
    assert_true(_run(world) > 0)
    _check_ints(world, expected)
    assert_equal(_run(world), 0)


def test_each_mutation_refreshes_columns() raises:
    """Runs one stale-copy check per column-revision-advancing operation.

    Raises:
        Error: If any path leaves a stale device column.
    """
    comptime if has_accelerator():
        comptime for path in range(7):
            _check_stale_path[path]()


def test_alternating_filters_evict_segments() raises:
    """Re-uploads a column whose packing changes between filters.

    Raises:
        Error: If differently packed runs reuse each other's segments.
    """
    comptime if has_accelerator():
        var world = _world()
        _ = world.storage.add_entity(Float32(2))
        world.reuse_device_copies(True)
        var context = SystemContext(world)
        for i in range(3):
            # Both filters pack their first store at offset 0.
            context.run[read_float_only_rows, on_device=True]()
            assert_equal(world._last_device_upload.bytes, size_of[Float32]())
            assert_true(_run(world) >= rows * size_of[Float32]())
            _check_ints(world, Int32(i + 1))


def test_escaped_column_pointer_needs_invalidation() raises:
    """Raw-pointer column writes stay invisible until invalidated.

    Raises:
        Error: If invalidation does not refresh the device column.
    """
    comptime if has_accelerator():
        var world = _world()
        world.reuse_device_copies(True)
        _ = _run(world)
        var floats = world.storage._archetypes[
            _store(world)
        ]._storage.get_component_ptr[Float32]()
        for i in range(rows):
            floats[unsafe_offset=i] = 4
        assert_equal(_run(world), 0)
        _check_ints(world, 2)
        world.invalidate_device_copies()
        assert_true(_run(world) > 0)
        _check_ints(world, 6)


def _run_selected(mut world: TestWorld, store: Int) raises -> Int:
    """Runs `accumulate` on rows 0, 1, and 4 of one store on the device.

    Args:
        world: World to run on.
        store: Store index of the selected rows.

    Raises:
        Error: If execution fails.

    Returns:
        Bytes uploaded by the invocation.
    """
    var context = SystemContext(world)
    var selection = context._empty_selection()
    selection._ranges.append(EntityRange(store, 0, 2))
    selection._ranges.append(EntityRange(store, 4, 1))
    selection.run[accumulate, on_device=True]()
    selection^.release()
    return world._last_device_upload.bytes


def test_selection_segments() raises:
    """Reuses exact selected ranges and re-uploads after a store change.

    Raises:
        Error: If selected segments are reused incorrectly.
    """
    comptime if has_accelerator():
        var world = _world()
        world.reuse_device_copies(True)
        var store = _store(world)
        comptime selected = 3 * (size_of[Int32]() + size_of[Float32]())

        assert_equal(_run_selected(world, store), selected)
        assert_equal(_run_selected(world, store), 0)
        # A write to an unselected row conservatively changes the store.
        world.storage.set(Entity(4), Float32(1))
        assert_equal(_run_selected(world, store), selected)
        assert_equal(world.storage.read[Int32](Entity(1)), 3)
        assert_equal(world.storage.read[Int32](Entity(4)), 0)
        assert_equal(world.storage.read[Int32](Entity(5)), 3)
        # A whole-store run packs different segments.
        assert_true(_run(world) > 0)


def test_world_copies_upload_columns_again() raises:
    """Starts copied worlds without device column records.

    Raises:
        Error: If a copy reuses its source world's records.
    """
    comptime if has_accelerator():
        var world = _world()
        world.reuse_device_copies(True)
        _ = _run(world)
        var copied = world.copy()
        comptime full = rows * (size_of[Int32]() + size_of[Float32]())
        assert_equal(_run(copied), full)
        assert_equal(_run(copied), 0)
        assert_equal(_run(world), 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
