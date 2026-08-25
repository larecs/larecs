import bitmask_benchmark
import world_benchmark
import component_benchmark
import query_benchmark
import resources_benchmark
from custom_benchmark import DefaultBench


def main() raises:
    var bench = DefaultBench()
    world_benchmark.run_all_world_benchmarks(bench)
    query_benchmark.run_all_query_benchmarks(bench)
    bitmask_benchmark.run_all_bitmask_benchmarks(bench)
    component_benchmark.run_all_component_benchmarks(bench)
    resources_benchmark.run_all_resource_benchmarks(bench)
    bench.dump_report()
