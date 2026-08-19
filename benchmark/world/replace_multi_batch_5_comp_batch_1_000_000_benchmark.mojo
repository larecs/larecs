from std.benchmark import Bencher
from larecs.test_utils import *

# FIXME There is a compiler inlining bug which leads to wrong query bitmasks being passed to the replace operation
#   when this is compiled together with other benchmarks. Either run this as a standalone executable or wait until the bug is fixed.


def benchmark_replace_5_comp_batch_1_000_000(
    mut bencher: Bencher,
):
    """Benchmark replacing 5 components over one 1,000,000-entity batch.

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
            count=1_000_000,
        )
    except e:
        print(e)
        return

    @always_inline
    def bench_fn() {mut world}:
        """Run one batch replace cycle in both component directions."""
        try:
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
                FlexibleComponent[4](9.0, 10.0),
            )
        except e:
            print(e)

    bencher.iter(bench_fn)
