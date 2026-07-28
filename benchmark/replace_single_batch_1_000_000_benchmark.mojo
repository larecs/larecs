from std.benchmark import Bench, Bencher, BenchId
from custom_benchmark import DefaultBench
from larecs.test_utils import *

# FIXME There is a compiler inlining bug which leads to wrong query bitmasks being passed to the replace operation
#   when this is compiled together with other benchmarks. Either run this as a standalone executable or wait until the bug is fixed.


def benchmark_replace_1_comp_batch_1_000_000(
    mut bencher: Bencher,
):
    """Benchmark replacing one component across one large batch.

    Args:
        bencher: The benchmark harness runner.
    """
    world = SmallWorld()
    try:
        _ = world.storage.add_entities(FlexibleComponent[0](1.0, 2.0), count=1_000_000)
    except e:
        print(e)
        return

    @always_inline
    def bench_fn() {imm, mut world}:
        """Run one replace-forward and replace-back cycle."""
        try:
            _ = world.storage.replace[FlexibleComponent[0]]().by(
                world.storage.query[FlexibleComponent[0]](),
                FlexibleComponent[1](3.0, 4.0),
            )

            _ = world.storage.replace[FlexibleComponent[1]]().by(
                world.storage.query[FlexibleComponent[1]](),
                FlexibleComponent[0](1.0, 2.0),
            )

        except e:
            print(e)

    bencher.iter(bench_fn)


def run_world_replace_single_batch_1_000_000_benchmark() raises:
    """Run the standalone one-million-entity replace benchmark.

    Raises:
        Error: If benchmark setup or report dumping fails.
    """
    bench = DefaultBench()
    run_world_replace_single_batch_1_000_000_benchmark(bench)
    bench.dump_report()


def run_world_replace_single_batch_1_000_000_benchmark(
    mut bench: Bench,
) raises:
    """Register the one-million-entity replace benchmark.

    Args:
        bench: The benchmark suite to register with.
    """
    bench.bench_function(
        benchmark_replace_1_comp_batch_1_000_000,
        BenchId("10^0 * replace 1 component 10^6 batch"),
    )
