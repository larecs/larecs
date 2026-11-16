"""Measures complete classification/sort/movement maintenance costs."""

from std.benchmark import Bench, BenchId, Bencher, keep
from std.os import abort
from custom_benchmark import DefaultBench
from larecs import World, Filter, SpatialClassifier
from larecs.entity import EntityAccessor


comptime ROW_COUNT = 100_000
"""Rows classified on every explicit pass."""


@fieldwise_init
struct Policy(SpatialClassifier):
    """Groups integer positions by explicit ascending identity keys."""

    comptime Accessor = EntityAccessor[Filter().read[Int]()]

    def classify(self, entity: Self.Accessor) raises -> UInt64:
        """Returns the nonnegative row's cluster key.

        Args:
            entity: Current integer classifier input.

        Raises:
            Error: The classifier interface permits errors; this policy does
                not raise recoverable errors.

        Returns:
            The integer component as the key.
        """
        return UInt64(entity.get[Int]())


def _bench_maintenance[mobile: Bool](mut bencher: Bencher):
    """Measures a full pass on ordered rows or constantly changing inputs.

    Parameters:
        mobile: Whether to reverse positions before each pass (included in timing).

    Args:
        bencher: Benchmark driver.
    """
    try:
        var world = World[Int, SIMD[DType.float32, 16]]()
        for i in range(ROW_COUNT):
            _ = world.storage.add_entity(i // 16, SIMD[DType.float32, 16](1))
        world.register_spatial_classifier[Filter().read[Int]()](Policy())
        var index = world.storage._entity_locations[1].archetype_index

        def run_once() {mut world, imm index}:
            """Includes classification, sort metadata, typed movement, and repair.
            """
            try:
                comptime if mobile:
                    var positions = world.storage._archetypes[
                        index
                    ]._storage.get_component_ptr[Int]()
                    for i in range(ROW_COUNT):
                        positions[unsafe_offset=i] = (
                            ROW_COUNT - 1
                        ) // 16 - positions[unsafe_offset=i]
                world.invalidate_spatial()
                world.maintain_spatial()
                keep(world.storage._archetypes[index].get_entity(0))
            except err:
                print(err)
                abort("Spatial maintenance benchmark failed")

        bencher.iter(run_once)
    except err:
        print(err)
        abort("Spatial maintenance benchmark setup failed")


def run_all_spatial_benchmarks(mut bench: Bench) raises:
    """Registers complete maintenance cost cases for 72-byte component rows.

    Args:
        bench: Benchmark registry.

    Raises:
        Error: If benchmark registration fails.
    """
    bench.bench_function(
        _bench_maintenance[False],
        BenchId(
            "spatial maintenance, 100k ordered, 72 component bytes per row"
        ),
        fixed_iterations=20,
    )
    bench.bench_function(
        _bench_maintenance[True],
        BenchId(
            "spatial maintenance, 100k mobile + reverse groups, 72 component"
            " bytes per row"
        ),
        fixed_iterations=20,
    )


def main() raises:
    """Runs complete maintenance cost benchmarks independently.

    Raises:
        Error: If benchmark setup or reporting fails.
    """
    var bench = DefaultBench()
    run_all_spatial_benchmarks(bench)
    bench.dump_report()
