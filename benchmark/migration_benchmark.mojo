"""Compare warmed single and batch structural changes on identical entity sets.

Run with `pixi run mojo run --lld-path /usr/bin/ld -I src
benchmark/migration_benchmark.mojo`. Timings exclude setup and compilation.
"""

from std.time import perf_counter_ns
from larecs.host_storage import HostStorage
from larecs.entity import Entity
from larecs.filter import Filter


def benchmark_migration[batch: Bool](size: Int, repeats: Int) raises:
    """Print mean add/remove and replacement cycle times per entity.

    Parameters:
        batch: Whether to migrate entire archetypes rather than individual rows.

    Args:
        size: Number of entities in each workload.
        repeats: Number of measured cycles after one warmup cycle.

    Raises:
        LarecsError: If a structural operation fails.
    """
    var storage = HostStorage[Int, Float64, Bool]()
    var entities = List[Entity]()
    for i in range(size):
        entities.append(storage.add_entity(i))
    var elapsed = Int(0)
    for cycle in range(repeats + 1):
        var start = perf_counter_ns()
        comptime if batch:
            _ = storage.add[
                Float64, filter=Filter().include[Int]().exclude[Float64]()
            ](Float64(2))
            _ = storage.remove[
                Float64, filter=Filter().include[Int, Float64]()
            ]()
            _ = storage.replace[Int]().by[
                filter=Filter().include[Int]().exclude[Bool]()
            ](Int(3), Bool(True))
            _ = storage.replace[Int, Bool]().by[
                filter=Filter().include[Int, Bool]()
            ](Int(4))
            _ = storage.replace[Int]().by[filter=Filter().include[Int]()](
                Int(5)
            )
        else:
            for entity in entities:
                storage.add(entity, Float64(2))
                storage.remove[Float64](entity)
                storage.replace[Int]().by(Int(3), Bool(True), entity=entity)
                storage.replace[Int, Bool]().by(Int(4), entity=entity)
                storage.replace[Int]().by(Int(5), entity=entity)
        if cycle:
            elapsed += perf_counter_ns() - start
    print(batch, size, Float64(elapsed) / Float64(size * repeats), sep=",")


def main() raises:
    """Measure single and batch cycles at small and large archetype sizes.

    Raises:
        LarecsError: If a benchmark operation fails.
    """
    print("batch,entities,ns_per_entity_cycle")
    benchmark_migration[False](1024, 100)
    benchmark_migration[True](1024, 100)
    benchmark_migration[False](65536, 20)
    benchmark_migration[True](65536, 20)
