from std.benchmark import Bencher
from larecs.test_utils import *

# FIXME There is a compiler inlining bug which leads to wrong query bitmasks being passed to the replace operation
#   when this is compiled together with other benchmarks. Either run this as a standalone executable or wait until the bug is fixed.


def benchmark_replace_5_comp_1_000_batch_1_000(
    mut bencher: Bencher,
):
    """Benchmark replacing 5 components across 1,000 repeated batches.

    Args:
        bencher: Benchmark harness that executes the measured closure.
    """
    world = SmallWorld()
    try:
        _ = world.storage.add_entities(
            FlexibleComponent[0](1.0, 2.0),
            FlexibleComponent[1](3.0, 4.0),
            FlexibleComponent[2](5.0, 6.0),
            FlexibleComponent[3](7.0, 8.0),
            FlexibleComponent[4](9.0, 10.0),
            count=1_000,
        )
    except e:
        print(e)
        return

    @always_inline
    def bench_fn() {mut world}:
        """Run 1,000-entity batch replacements in both component directions."""
        try:
            for _ in range(500):
                entity56789 = world.storage.add_entity(
                    FlexibleComponent[5](11.0, 12.0),
                    FlexibleComponent[6](13.0, 14.0),
                    FlexibleComponent[7](15.0, 16.0),
                    FlexibleComponent[8](17.0, 18.0),
                    FlexibleComponent[9](19.0, 20.0),
                )  # make sure target archetype has already one entity to not take optimized path for empty archetype
                _ = world.storage.replace[
                    FlexibleComponent[0],
                    FlexibleComponent[1],
                    FlexibleComponent[2],
                    FlexibleComponent[3],
                    FlexibleComponent[4],
                ]().by(
                    world.storage.query[
                        FlexibleComponent[0],
                        FlexibleComponent[1],
                        FlexibleComponent[2],
                        FlexibleComponent[3],
                        FlexibleComponent[4],
                    ](),
                    FlexibleComponent[5](11.0, 12.0),
                    FlexibleComponent[6](13.0, 14.0),
                    FlexibleComponent[7](15.0, 16.0),
                    FlexibleComponent[8](17.0, 18.0),
                    FlexibleComponent[9](19.0, 20.0),
                )
                world.storage.remove_entity(
                    entity56789
                )  # cleanup deoptimization entity to not increase amount of entities moved during replace in next iterations
                entity01234 = world.storage.add_entity(
                    FlexibleComponent[0](1.0, 2.0),
                    FlexibleComponent[1](3.0, 4.0),
                    FlexibleComponent[2](5.0, 6.0),
                    FlexibleComponent[3](7.0, 8.0),
                    FlexibleComponent[4](9.0, 10.0),
                )  # make sure target archetype has already one entity to not take optimized path for empty archetype
                _ = world.storage.replace[
                    FlexibleComponent[5],
                    FlexibleComponent[6],
                    FlexibleComponent[7],
                    FlexibleComponent[8],
                    FlexibleComponent[9],
                ]().by(
                    world.storage.query[
                        FlexibleComponent[5],
                        FlexibleComponent[6],
                        FlexibleComponent[7],
                        FlexibleComponent[8],
                        FlexibleComponent[9],
                    ](),
                    FlexibleComponent[0](1.0, 2.0),
                    FlexibleComponent[1](3.0, 4.0),
                    FlexibleComponent[2](5.0, 6.0),
                    FlexibleComponent[3](7.0, 8.0),
                    FlexibleComponent[4](9.0, 0.0),
                )
                world.storage.remove_entity(
                    entity01234
                )  # cleanup deoptimization entity to not increase amount of entities moved during replace in next iterations
        except e:
            print(e)

    bencher.iter(bench_fn)
