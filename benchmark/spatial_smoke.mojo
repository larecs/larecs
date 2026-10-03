"""Small deterministic cell-local workloads for per-PR performance checks."""

from std.benchmark import keep
from std.time import perf_counter_ns
from larecs import Entity, Filter, SpatialClassifier, World
from larecs.entity import EntityAccessor


@fieldwise_init
struct CellPolicy(SpatialClassifier):
    """Uses the explicit cell component as an ascending spatial key."""

    comptime Accessor = EntityAccessor[Filter().read[Int]()]

    def classify(self, entity: Self.Accessor) raises -> UInt64:
        """Reads an entity's current cell key.

        Args:
            entity: Read-only cell accessor.

        Raises:
            Error: If component access fails.

        Returns:
            The nonnegative cell key.
        """
        return UInt64(entity.get[Int]())


def measure(
    rows: Int,
    group: Int,
    stride: Int,
    cadence: Int,
    ordered: Bool,
    maintenance_only: Bool = False,
) raises:
    """Reports nanoseconds per frame for identical stable-ID cell gathers.

    Args:
        rows: Power-of-two entity count.
        group: Entities per cell.
        stride: Distance between occupied cell keys.
        cadence: Maintenance interval; zero denotes a static workload.
        ordered: Whether to order rows and maintain them during mobile frames.
        maintenance_only: Measure ordered scans or repeated key reversals alone.

    Raises:
        Error: If setup, maintenance, access, or checksum validation fails.
    """
    comptime Payload = SIMD[DType.float64, 16]
    var world = World[Int, Payload]()
    var visits = List[Entity]()
    for _ in range(rows):
        visits.append(Entity())
    for i in range(rows):
        var logical = (i * 109) % rows
        visits[logical] = world.storage.add_entity(
            (logical // group) * stride, Payload(Float64(logical + 1))
        )
    world.register_spatial_classifier[Filter().read[Int]()](CellPolicy())
    if ordered:
        world.maintain_spatial()

    var expected_frame = Float64(0)
    for cell in range(rows // group):
        var total = Float64(8 * group * (2 * cell * group + group + 1))
        expected_frame += total * total

    # Calibrate a bounded batch to >=20ms, keeping setup outside the timer.
    var frames = 8
    var elapsed: Int
    while True:
        var checksum = Float64(0)
        var start = perf_counter_ns()
        for frame in range(frames):
            if maintenance_only:
                if not ordered:
                    var index = world.storage._entity_locations[
                        1
                    ].archetype_index
                    ref archetype = world.storage._archetypes[index]
                    var cells = archetype._storage.get_component_ptr[Int]()
                    for i in range(rows):
                        cells[unsafe_offset=i] = (
                            (rows // group - 1) * stride
                        ) - cells[unsafe_offset=i]
                world.maintain_spatial()
                keep(world.storage._entity_locations[1].entity_index)
                continue
            if cadence > 0:
                # Logical cells rotate, preserving membership within each cell.
                # Each frame assigns absolute keys, independent of the previous batch.
                for logical in range(rows):
                    world.storage.get[Int](visits[logical]) = (
                        (logical // group + frame + 1) % (rows // group)
                    ) * stride
                if ordered and frame % cadence == 0:
                    world.maintain_spatial()
            var rotation = 0
            if cadence > 0:
                rotation = ((frame + 1) % (rows // group)) * group
            # Traverse cells in key order using stable IDs. All SIMD lanes are
            # consumed; both layouts perform exactly the same semantic work.
            var cell_sum = Float64(0)
            var previous_cell = -1
            for j in range(rows):
                var logical = (j + rows - rotation) % rows
                var cell = world.storage.get[Int](visits[logical])
                if cell != previous_cell:
                    checksum += cell_sum * cell_sum
                    cell_sum = 0
                    previous_cell = cell
                cell_sum += Float64(
                    world.storage.get[Payload](visits[logical]).reduce_add()
                )
            checksum += cell_sum * cell_sum
            keep(checksum)
        elapsed = Int(perf_counter_ns() - start)
        if (
            not maintenance_only
            and checksum != Float64(frames) * expected_frame
        ):
            raise Error("Spatial smoke checksum mismatch")
        if elapsed >= 20_000_000 or frames >= 8192:
            break
        frames *= 2
    # Validate payload preservation and sorted maintenance output outside timing.
    for logical in range(rows):
        var payload = world.storage.get[Payload](visits[logical])
        for lane in range(16):
            if payload[lane] != Float64(logical + 1):
                raise Error("Spatial smoke payload/location corruption")
    if maintenance_only or (ordered and cadence == 0):
        var previous = -1
        for row in world.storage.query[Filter().read[Int]()]():
            var cell = row.get[Int]()
            if cell < previous:
                raise Error("Spatial smoke ordering mismatch")
            previous = cell
    print(
        "SPATIAL",
        rows,
        group,
        stride,
        cadence,
        Int(ordered),
        Int(maintenance_only),
        Float64(elapsed) / Float64(frames),
    )


def main() raises:
    """Runs static and mobile comparisons in a bounded, CPU-only suite.

    Raises:
        Error: If any scenario fails validation or execution.
    """
    for size in range(2):
        var rows = 512 << (size * 2)
        for layout in range(2):
            var ordered = Bool(layout)
            measure(rows, 8, 1, 0, ordered)  # uniform cells
            measure(rows, 64, 1, 0, ordered)  # dense cells
            measure(rows, 8, 1024, 0, ordered)  # sparse occupied cells
            measure(rows, 8, 1, 0, ordered, True)
            measure(rows, 64, 1, 0, ordered, True)
            measure(rows, 8, 1024, 0, ordered, True)
            measure(rows, 8, 1, 1, ordered)  # maintenance every frame
            measure(rows, 8, 1, 4, ordered)  # maintenance every fourth frame
