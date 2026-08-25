from world.entity_benchmark import run_all_world_entity_benchmarks
from world.access_benchmark import run_all_world_access_benchmarks
from world.component_single_benchmark import (
    run_all_world_component_single_benchmarks,
)
from world.component_single_batch_benchmark import (
    run_all_world_component_single_batch_benchmarks,
)
from world.component_multi_benchmark import (
    run_all_world_component_multi_benchmarks,
)
from world.component_multi_batch_benchmark import (
    run_all_world_component_multi_batch_benchmarks,
)
from world.replace_single_benchmark import (
    run_all_world_replace_single_benchmarks,
)
from world.replace_single_1_000_batch_1_000_benchmark import (
    benchmark_replace_1_comp_1_000_batch_1_000,
)
from world.replace_single_batch_1_000_000_benchmark import (
    benchmark_replace_1_comp_batch_1_000_000,
)
from world.replace_multi_benchmark import run_all_world_replace_multi_benchmarks
from world.replace_multi_batch_5_comp_1_000_batch_1_000_benchmark import (
    benchmark_replace_5_comp_1_000_batch_1_000,
)
from world.replace_multi_batch_5_comp_batch_1_000_000_benchmark import (
    benchmark_replace_5_comp_batch_1_000_000,
)
from std.benchmark import Bench, BenchId
from custom_benchmark import DefaultBench


def run_all_world_benchmarks() raises:
    bench = DefaultBench()
    run_all_world_benchmarks(bench)
    bench.dump_report()


def run_all_world_benchmarks(mut bench: Bench) raises:
    run_all_world_entity_benchmarks(bench)
    run_all_world_access_benchmarks(bench)
    run_all_world_component_single_benchmarks(bench)
    run_all_world_component_single_batch_benchmarks(bench)
    run_all_world_component_multi_benchmarks(bench)
    run_all_world_component_multi_batch_benchmarks(bench)
    run_all_world_replace_single_benchmarks(bench)
    bench.bench_function(
        benchmark_replace_1_comp_batch_1_000_000,
        BenchId("10^0 * replace 1 component 10^6 batch"),
    )
    bench.bench_function(
        benchmark_replace_1_comp_1_000_batch_1_000,
        BenchId("10^3 * replace 1 component 10^3 batch"),
    )
    run_all_world_replace_multi_benchmarks(bench)
    bench.bench_function(
        benchmark_replace_5_comp_batch_1_000_000,
        BenchId("10^0 * replace 5 components 10^6 batch"),
    )
    bench.bench_function(
        benchmark_replace_5_comp_1_000_batch_1_000,
        BenchId("10^3 * replace 5 components 10^3 batch"),
    )
