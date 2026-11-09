+++
type = "docs"
title = "Measure an implementation change"
weight = 5
+++

Use representative workloads to compare a storage, query, movement, or execution
change. We validate semantic equivalence before interpreting elapsed time;
application profiling starts in [Measure and tune a simulation](../../../guide/performance/measure).

## Benchmark methodology

Build a focused manual driver once with
`pixi run mojo build -I src benchmark/<benchmark_filename>.mojo -o /tmp/larecs-benchmark`,
then run `/tmp/larecs-benchmark` repeatedly. Run the complete manual suite with
`pixi run mojo run -I src benchmark/run_benchmarks.mojo`.

When changing storage, queries, classification, row movement, or execution costs,
add or update representative benchmarks using these criteria:

- Keep the combined PR performance checks near one minute per runner, including
  compilation, warmup, and sampling. Measure cold compilation and execution
  separately on Linux and macOS before expanding the suite. Keep large worlds,
  GPU cases, and the complete benchmark registry in focused manual drivers.
- Use deterministic inputs, bounded calibration or fixed iteration counts, and a
  compact scenario matrix. Spatial cases should cover uniform, dense, sparse,
  and moving entities with different maintenance cadences.
- Compare identical entities and semantic work, with an unchanged-layout control.
  Measure isolated operations and complete frames when useful. Include input
  updates, classification, sorting, movement, location repair, and transfers
  whenever they belong to the claimed workload. State excluded setup and
  maintenance costs; validate results, locations, and payload preservation
  outside the timer, and consume results to prevent dead-code elimination.
- Build each timing binary once, then run it repeatedly. Compare the same current
  driver against baseline and current libraries on the same runner with matching
  compiler versions and optimization settings. Use optimized builds without
  debug info, sanitizers, or tracing. Run builds and measurements sequentially,
  with no competing benchmark jobs, and report compilation separately.
- Warm both binaries, alternate baseline/current order, and use repeated paired
  samples. Keep machine-specific timing baselines out of the repository. See
  [PR performance checks](../regression#pr-to-pr-performance-checks) and
  [spatial checks](../regression#small-spatial-benchmarks-on-every-pr) for baseline selection,
  thresholds, confirmation, and support for revisions predating the spatial API.
- Keep the small regression checks in `pixi run tests test` on Linux and macOS;
  focused test-file runs omit performance checks. Investigate sustained failures
  and document evidence before changing thresholds; use dedicated measurements
  for smaller regressions.
- Keep scenario matrices and expected-case manifests synchronized. Invalid or
  incomplete reports, build failures, and correctness failures must fail checks.
  Update the regression reference when changing cases, timing boundaries, sampling, or baseline
  selection. Record hardware, compiler, method, and limitations with performance
  claims; track unmeasured benefits and remaining work in the roadmap.

## Focused driver selection

| Mechanism | Checked driver and evidence |
| --- | --- |
| Exact selections and structural batches | `benchmark/entity_selection_benchmark.mojo`; [selection reports](../reports/selection). |
| Implemented threaded engine | `benchmark/threaded_execution.mojo`; [threaded report](../reports/threaded). |
| Scalar atomics and uncontended guards | `benchmark/synchronization_benchmark.mojo`; [protocol and limits](../reports/synchronization). |
| Dirty classification | `benchmark/dirty_spatial.mojo`; [deferred maintenance report](../reports/dirty_spatial). |
| Growable partition placement | `benchmark/partitioned_spatial.mojo`; [current and historical layouts](../reports/partitions). |
| Ordinary and adapted resources | `benchmark/resource_execution_benchmark.mojo` and `benchmark/resource_adapter_benchmark.mojo`; [resource report](../reports/resources). |

For a new comparison, retain hardware/OS, compiler build, both library revisions,
driver hash, flags, warmup/calibration, paired raw samples, correctness results,
and excluded costs. If a historical record lacks a field, label it unknown
rather than reconstructing a claim from a machine name. Keep timing reports
separate from application instructions and from the roadmap's unfinished work.
