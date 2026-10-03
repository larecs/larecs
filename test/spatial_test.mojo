"""Spatial registration, full-scan maintenance, and coordinate helpers."""

from std.testing import (
    assert_equal,
    assert_true,
    assert_false,
    assert_raises,
    TestSuite,
)
from larecs import (
    World,
    Filter,
    SpatialClassifier,
    grid_cell,
    morton_key_3d,
    SystemContext,
    KernelContext,
)
from larecs.entity import Entity, EntityAccessor
from larecs.host_storage import HostStorage


@fieldwise_init
struct Position(Copyable, Movable):
    """Spatial classifier input."""

    var x: Float64


@fieldwise_init
struct Payload(Copyable, Movable):
    """Heap-backed column not read by the classifier."""

    var values: List[Int]


@fieldwise_init
struct Excluded(Copyable, Movable):
    """Marks archetypes that must not be classified."""

    pass


comptime spatial_filter = Filter().read[Position]().exclude[Excluded]()


@fieldwise_init
struct GridPolicy[filter: Filter = spatial_filter](SpatialClassifier):
    """Owned grid configuration with checked coordinate encoding."""

    comptime Accessor = EntityAccessor[Self.filter]
    var size: Float64

    def classify(self, entity: Self.Accessor) raises -> UInt64:
        """Computes a key from position.

        Args:
            entity: Read-only position accessor.

        Raises:
            Error: If the position or cell size is invalid.

        Returns:
            The encoded planar cell key.
        """
        return morton_key_3d(grid_cell(entity.get[Position]().x, self.size), 0)


def test_spatial_order_preserves_ids_payload_and_membership() raises:
    """Classification reorders all columns and repairs entity locations.

    Raises:
        Error: If setup, maintenance, or an assertion fails.
    """
    var world = World[Position, Payload, Excluded]()
    var entities = List[Entity]()
    for value in [3, -2, 3, 0, -2]:
        entities.append(
            world.storage.add_entity(
                Position(Float64(value)), Payload([value, value + 10])
            )
        )
    var excluded = world.storage.add_entity(
        Position(Float64(1.0) / Float64(0.0)), Excluded()
    )
    world.register_spatial_classifier[spatial_filter](GridPolicy(1))
    world.maintain_spatial()
    var keys = List[UInt64]()
    for row in world.storage.query[spatial_filter]():
        keys.append(morton_key_3d(grid_cell(row.get[Position]().x, 1), 0))
    assert_equal(len(keys), 5)
    for i in range(1, len(keys)):
        assert_true(keys[i - 1] <= keys[i])
    for i in range(len(entities)):
        var value = world.storage.get[Position](entities[i]).x
        assert_equal(
            world.storage.get[Payload](entities[i]).values[0], Int(value)
        )
        assert_equal(
            world.storage.get[Payload](entities[i]).values[1], Int(value) + 10
        )
    assert_true(world.storage.is_alive(excluded))
    assert_equal(len(world), 6)
    world.maintain_spatial()
    assert_false(world.storage.is_locked())


def test_spatial_registration_lock_and_duplicate() raises:
    """Queries and selections reject maintenance; registration is singular.

    Raises:
        Error: If setup, maintenance, or an assertion fails.
    """
    var world = World[Position, Excluded]()
    _ = world.storage.add_entity(Position(2))
    var query = world.storage.query[spatial_filter]()
    with assert_raises():
        world.register_spatial_classifier[spatial_filter](GridPolicy(1))
    with assert_raises():
        world.maintain_spatial()
    _ = query^
    world.register_spatial_classifier[spatial_filter](GridPolicy(1))
    with assert_raises(contains="already registered"):
        world.register_spatial_classifier[spatial_filter](GridPolicy(2))
    var context = SystemContext(world)
    var selection = context.add_entities(Position(0), count=1)
    with assert_raises():
        context.world[].maintain_spatial()
    selection^.release()
    context.world[].maintain_spatial()


def test_grid_bounds_floor_and_morton_identity() raises:
    """Negative cells floor correctly; out-of-range keys never wrap.

    Raises:
        Error: If coordinate encoding or an assertion fails.
    """
    assert_equal(grid_cell(-0.01, 1), -1)
    assert_equal(grid_cell(-1, 1), -1)
    assert_equal(grid_cell(-1.01, 1), -2)
    assert_equal(grid_cell(3.9, 2), 1)
    assert_equal(morton_key_3d(-1048576, -1048576, -1048576), UInt64(0))
    assert_equal(
        morton_key_3d(1048575, 1048575, 1048575), (UInt64(1) << 63) - 1
    )
    var seen = Dict[UInt64, Bool]()
    for x in range(-3, 4):
        for y in range(-3, 4):
            for z in range(-3, 4):
                var key = morton_key_3d(x, y, z)
                assert_false(key in seen)
                seen[key] = True
    for size in [
        0.0,
        -1.0,
        Float64(1.0) / Float64(0.0),
        Float64(0.0) / Float64(0.0),
    ]:
        with assert_raises():
            _ = grid_cell(1, size)
    for value in [
        Float64(1.0) / Float64(0.0),
        Float64(0.0) / Float64(0.0),
        1048576.0,
        -1048577.0,
    ]:
        with assert_raises():
            _ = grid_cell(value, 1)
    with assert_raises():
        _ = morton_key_3d(1048576, 0)
    with assert_raises():
        _ = morton_key_3d(0, -1048577)
    with assert_raises():
        _ = morton_key_3d(0, 0, 1048576)


@fieldwise_init
struct RecordingPolicy(SpatialClassifier):
    """Counts classifier invocations through a test-owned counter."""

    comptime Accessor = EntityAccessor[spatial_filter]
    var calls: Pointer[Int, MutUntrackedOrigin]

    def classify(self, entity: Self.Accessor) raises -> UInt64:
        """Records a classification and computes its key.

        Args:
            entity: Position to classify.

        Raises:
            Error: If coordinate encoding fails.

        Returns:
            A position-based cluster key.
        """
        self.calls[] += 1
        return morton_key_3d(grid_cell(entity.get[Position]().x, 1), 0)


def reverse_positions(context: KernelContext[Filter().include[Position]()]):
    """Changes classifier inputs without requesting maintenance.

    Args:
        context: Position columns to update.
    """
    for entity in context:
        entity.get[Position]().x = -entity.get[Position]().x


def test_full_scans_and_no_implicit_maintenance() raises:
    """Every explicit pass rescans ordered rows; writes and kernels do not.

    Raises:
        Error: If setup, maintenance, or an assertion fails.
    """
    var world = World[Position, Excluded]()
    var calls = 0
    world.register_spatial_classifier[spatial_filter](
        RecordingPolicy(
            Pointer(to=calls).unsafe_origin_cast[MutUntrackedOrigin]()
        )
    )
    var a = world.storage.add_entity(Position(2))
    var b = world.storage.add_entity(Position(-1))
    _ = world.storage.add_entity(Position(10), Excluded())
    assert_equal(calls, 0)
    world.maintain_spatial()
    assert_equal(calls, 2)
    world.maintain_spatial()
    assert_equal(calls, 4)
    var index = world.storage._entity_locations[a.get_id()].archetype_index
    assert_equal(world.storage._archetypes[index].get_entity(0), b)
    world.storage.get[Position](a).x = 5
    var context = SystemContext(world)
    context.run[reverse_positions]()
    assert_equal(calls, 4)
    assert_equal(context.world[].storage._archetypes[index].get_entity(0), b)
    context.world[].maintain_spatial()
    assert_equal(calls, 6)
    assert_equal(context.world[].storage._archetypes[index].get_entity(0), a)


def test_classifier_failure_preserves_all_archetypes_and_unlocks() raises:
    """A later archetype failure leaves earlier unordered archetypes intact.

    Raises:
        Error: If setup, maintenance, or an assertion fails.
    """
    var world = World[Position, Payload, Excluded]()
    var a = world.storage.add_entity(Position(3))
    var b = world.storage.add_entity(Position(0))
    var c = world.storage.add_entity(Position(2), Payload([2]))
    var invalid = world.storage.add_entity(Position(1048576), Payload([9]))
    world.register_spatial_classifier[spatial_filter](GridPolicy(1))
    with assert_raises(contains="signed 21-bit"):
        world.maintain_spatial()
    assert_false(world.storage.is_locked())
    var index = world.storage._entity_locations[a.get_id()].archetype_index
    assert_equal(world.storage._archetypes[index].get_entity(0), a)
    assert_equal(world.storage._archetypes[index].get_entity(1), b)
    index = world.storage._entity_locations[c.get_id()].archetype_index
    assert_equal(world.storage._archetypes[index].get_entity(0), c)
    assert_equal(world.storage._archetypes[index].get_entity(1), invalid)
    world.storage.get[Position](invalid).x = -3
    world.maintain_spatial()
    assert_equal(world.storage._archetypes[index].get_entity(0), invalid)
    assert_equal(world.storage.get[Payload](invalid).values[0], 9)


def test_exclusive_empty_and_owned_world_copy() raises:
    """Exclusive matching, empty archetypes, and copied policy configuration work.

    Raises:
        Error: If setup, maintenance, or an assertion fails.
    """
    comptime only_position = Filter().read[Position]().exclusive()
    var world = World[Position, Payload, Excluded]()
    world.maintain_spatial()  # No registration and no entities.
    var dead = world.storage.add_entity(Position(1))
    world.storage.remove_entity(dead)  # Keep an empty eligible archetype.
    _ = world.storage.add_entity(Position(1048576), Payload([1]))
    world.register_spatial_classifier[only_position](
        GridPolicy[only_position](2)
    )
    world.maintain_spatial()  # Nonmatching invalid inputs must never be read.
    _ = world.storage.add_entity(
        Position(1048576)
    )  # Valid only with cell size 2.
    var copy = world.copy()
    _ = world^
    copy.maintain_spatial()
    assert_equal(len(copy), 2)


@fieldwise_init
struct OwnedGridPolicy(SpatialClassifier):
    """Heap-backed policy configuration owned by the world."""

    comptime Accessor = EntityAccessor[spatial_filter]
    var sizes: List[Float64]

    def classify(self, entity: Self.Accessor) raises -> UInt64:
        """Classifies using an owned cell width.

        Args:
            entity: Position input for the policy.

        Raises:
            Error: If coordinate encoding fails.

        Returns:
            The encoded position key.
        """
        return morton_key_3d(
            grid_cell(entity.get[Position]().x, self.sizes[0]), 0
        )


def test_heap_policy_copy_and_move_ownership() raises:
    """Policy configuration remains valid after copying and destroying a world.

    Raises:
        Error: If setup, maintenance, or an assertion fails.
    """
    var world = World[Position, Excluded]()
    _ = world.storage.add_entity(Position(1048576))
    world.register_spatial_classifier[spatial_filter](OwnedGridPolicy([2.0]))
    var copy = world.copy()
    _ = world^
    var moved = copy^
    moved.maintain_spatial()
    assert_equal(len(moved), 1)


@fieldwise_init
struct ReentrantPolicy(SpatialClassifier):
    """Intentionally invalid policy used to check callback structural locking.
    """

    comptime Accessor = EntityAccessor[spatial_filter]
    var storage: Pointer[HostStorage[Position, Excluded], MutUntrackedOrigin]

    def classify(self, entity: Self.Accessor) raises -> UInt64:
        """Attempts forbidden entity creation during a classifier callback.

        Args:
            entity: Unused borrowed classifier accessor.

        Raises:
            Error: Preserves the expected locked-world diagnostic.

        Returns:
            Zero if the forbidden operation unexpectedly succeeds.
        """
        try:
            _ = self.storage[].add_entity(Position(0))
        except err:
            raise Error(String(err))
        return 0


def test_classifier_callback_rejects_structural_reentrancy() raises:
    """Classification holds and releases its structural lock on callback errors.

    Raises:
        Error: If setup, maintenance, or an assertion fails.
    """
    var world = World[Position, Excluded]()
    var entity = world.storage.add_entity(Position(3))
    world.register_spatial_classifier[spatial_filter](
        ReentrantPolicy(
            Pointer(to=world.storage).unsafe_origin_cast[MutUntrackedOrigin]()
        )
    )
    with assert_raises(contains="locked world"):
        world.maintain_spatial()
    assert_false(world.storage.is_locked())
    assert_equal(len(world), 1)
    assert_equal(world.storage.get[Position](entity).x, 3)


@fieldwise_init
struct UnsignedPolicy(SpatialClassifier):
    """Uses the entire unsigned key range without spatial encoding."""

    comptime Accessor = EntityAccessor[Filter().read[UInt64]()]

    def classify(self, entity: Self.Accessor) raises -> UInt64:
        """Returns an application key directly.

        Args:
            entity: Read-only key component accessor.

        Raises:
            Error: The classifier interface permits errors; this policy does
                not raise recoverable errors.

        Returns:
            The full-width unsigned key.
        """
        return entity.get[UInt64]()


def test_full_unsigned_key_order() raises:
    """Keys above the signed range still sort in ascending unsigned order.

    Raises:
        Error: If setup, maintenance, or an assertion fails.
    """
    var world = World[UInt64]()
    for key in [(UInt64(0) - 1), UInt64(0), UInt64(1) << 63, UInt64(7)]:
        _ = world.storage.add_entity(key)
    world.register_spatial_classifier[Filter().read[UInt64]()](UnsignedPolicy())
    world.maintain_spatial()
    var expected = [UInt64(0), UInt64(7), UInt64(1) << 63, (UInt64(0) - 1)]
    var index = 0
    for row in world.storage.query[Filter().read[UInt64]()]():
        assert_equal(row.get[UInt64](), expected[index])
        index += 1
    assert_equal(index, len(expected))


def main() raises:
    """Runs spatial regression tests.

    Raises:
        Error: If a test fails.
    """
    TestSuite.discover_tests[__functions_in_module()]().run()
