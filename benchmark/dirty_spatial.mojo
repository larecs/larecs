"""Paired deferred/full-scan complete-frame comparisons with identical entities."""

from std.benchmark import keep
from std.time import perf_counter_ns
from std.testing import assert_equal, assert_true
from larecs import Entity, Filter, SpatialClassifier, World, morton_key_3d
from larecs.entity import EntityAccessor


@fieldwise_init
struct Policy(SpatialClassifier):
    """Computes a multidimensional key from the application cell input."""

    comptime Accessor = EntityAccessor[Filter().read[Int]()]

    def classify(self, entity: Self.Accessor) raises -> UInt64:
        """Encodes the current cell.

        Args:
            entity: Read-only cell input.

        Raises:
            Error: If the cell exceeds the encoding bounds.

        Returns:
            The checked Morton key.
        """
        return morton_key_3d(entity.get[Int](), 0)


comptime Payload = SIMD[DType.int64, 8]
comptime SpatialWorld = World[Int, Payload]


def prepare(rows: Int, group: Int, stride: Int) raises -> SpatialWorld:
    """Constructs identical scrambled worlds and establishes their initial order.

    Args:
        rows: Power-of-two entity count.
        group: Entities sharing a cell.
        stride: Distance between occupied cells.

    Raises:
        Error: If setup or initial maintenance fails.

    Returns:
        An owned, maintained world with stable-ID payloads.
    """
    var world = SpatialWorld()
    for row in range(rows):
        var logical = (row * 109) % rows
        _ = world.storage.add_entity(
            (logical // group) * stride, Payload(row + 1)
        )
    world.register_spatial_classifier[Filter().read[Int]()](Policy())
    world.maintain_spatial()
    return world^


def sample(
    mut world: SpatialWorld,
    rows: Int,
    dirty: Int,
    full: Bool,
    group: Int,
    stride: Int,
    sample_index: Int,
) raises -> Float64:
    """Times updates, marking, classification, sorting, movement, and repair.

    Args:
        world: Initially maintained world reused across paired samples.
        rows: Total entities.
        dirty: Distinct identities to update twice per frame.
        full: Whether to force full-scan classification after the same updates.
        group: Initial entities sharing a cell.
        stride: Initial distance between cells.
        sample_index: Zero-based batch number, including warmup.

    Raises:
        Error: If component updates, maintenance, or validation fails.

    Returns:
        Nanoseconds per complete frame in a fixed batch (1024 clean, 16 dirty).
    """
    var frame_count = 1024 if dirty == 0 else 16
    var start = perf_counter_ns()
    for frame in range(frame_count):
        for id in range(1, dirty + 1):
            var entity = Entity(id)
            world.storage.get[Int](entity) += 1
            world.storage.get[Int](entity) -= 1 if frame % 2 else 0
        if full:
            world.invalidate_spatial()
        world.maintain_spatial()
        keep(world.storage._entity_locations[1].entity_index)
    var elapsed = Float64(perf_counter_ns() - start) / Float64(frame_count)
    # Validate complete key ordering, identity/location repair, and every payload
    # outside timing, using immutable queries so validation cannot mark inputs.
    var previous = UInt64(0)
    var seen = 0
    for row in world.storage.query[Filter().read[Int, Payload]()]():
        var key = morton_key_3d(row.get[Int](), 0)
        assert_true(key >= previous)
        previous = key
        var entity = row.get_entity()
        var id = Int(entity.get_id())
        var initial = (((id - 1) * 109) % rows // group) * stride
        var advance = 8 * (sample_index + 1) if id <= dirty else 0
        assert_equal(row.get[Int](), initial + advance)
        assert_equal(row.get[Payload](), Payload(Int(entity.get_id())))
        var location = world.storage._entity_locations[entity.get_id()]
        assert_equal(
            world.storage._archetypes[location.archetype_index].get_entity(
                location.entity_index
            ),
            entity,
        )
        seen += 1
    assert_equal(seen, rows)
    return elapsed


def main() raises:
    """Warms both paths then alternates five pairs for a compact scenario matrix.

    Raises:
        Error: If setup, timing, or correctness validation fails.
    """
    for rows in [2048, 32768]:
        for distribution in range(3):
            var group = 256 if distribution == 1 else 16
            var stride = 128 if distribution == 2 else 1
            for dirty in [0, 1, rows // 64, rows]:
                var deferred = prepare(rows, group, stride)
                var scanned = prepare(rows, group, stride)
                _ = sample(deferred, rows, dirty, False, group, stride, 0)
                _ = sample(scanned, rows, dirty, True, group, stride, 0)
                for pair in range(5):
                    var dirty_ns: Float64
                    var full_ns: Float64
                    if pair % 2 == 0:
                        dirty_ns = sample(
                            deferred,
                            rows,
                            dirty,
                            False,
                            group,
                            stride,
                            pair + 1,
                        )
                        full_ns = sample(
                            scanned, rows, dirty, True, group, stride, pair + 1
                        )
                    else:
                        full_ns = sample(
                            scanned, rows, dirty, True, group, stride, pair + 1
                        )
                        dirty_ns = sample(
                            deferred,
                            rows,
                            dirty,
                            False,
                            group,
                            stride,
                            pair + 1,
                        )
                    print(
                        "DIRTY",
                        rows,
                        distribution,
                        dirty,
                        pair,
                        dirty_ns,
                        full_ns,
                    )
