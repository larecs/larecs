import bitmask_benchmark
import world_benchmark
import component_benchmark
import query_benchmark
import resources_benchmark
import gpu_system_benchmark
import entity_selection_benchmark
import row_reordering_benchmark
import spatial_benchmark
from custom_benchmark import DefaultBench


def main() raises:
    var bench = DefaultBench()
    world_benchmark.run_all_world_benchmarks(bench)
    query_benchmark.run_all_query_benchmarks(bench)
    bitmask_benchmark.run_all_bitmask_benchmarks(bench)
    component_benchmark.run_all_component_benchmarks(bench)
    resources_benchmark.run_all_resource_benchmarks(bench)
    gpu_system_benchmark.run_all_gpu_system_benchmarks(bench)
    entity_selection_benchmark.run_all_entity_selection_benchmarks(bench)
    row_reordering_benchmark.run_all_row_reordering_benchmarks(bench)
    spatial_benchmark.run_all_spatial_benchmarks(bench)
    bench.dump_report()
