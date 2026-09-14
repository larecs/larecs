from std.benchmark import (
    BenchConfig,
    Bench,
)


def DefaultConfig() raises -> BenchConfig:
    """Returns the default configuration for benchmarking."""
    var config = BenchConfig(
        min_runtime_secs=2.0, max_runtime_secs=10.0, max_batch_size=50
    )
    config.verbose_timing = True
    return config^


def DefaultBench() raises -> Bench:
    """Returns the default benchmarking struct."""
    return Bench(DefaultConfig())
