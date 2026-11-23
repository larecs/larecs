+++
type = "docs"
title = "Benchmarks"
weight = 100
+++

The focused `entity_selection_benchmark.mojo` workload compares ordinary
full-world CPU execution with contiguous and disjoint 64-row selections in a
100,000-row world, a selected add/remove chain, and selected GPU execution when
an accelerator is available. On the Apple Metal development host used for the
1.0.0b2 work, one bounded run measured approximately 0.0253 ms for the 100k-row
CPU path, 0.0000664 ms for the contiguous selection, 0.000556 ms for 64 disjoint
single-row ranges, 0.00727 ms for the add/remove chain, and 0.379 ms for the GPU
selection. These are development measurements, not a cross-version historical
baseline; use the benchmark on target hardware for regression decisions.

## Shared CPU execution comparison

The focused selection driver also measures thin and lexical CPU kernels over
seven matching archetypes (512 rows each) alongside six nonmatching archetypes
(512 rows each). All matching rows perform the same increment; the closure also
counts range invocations. Construction and result checks are excluded, and
checks outside the timer verify row count, every row against `Bencher.num_iters`,
and the closure's exact invocation count and accumulated values.
These cases remain manual benchmarks; they are not added to the small PR suite.

On Apple M4, macOS 27.0.1, Mojo 1.0.0 (`ed45d567`), the shared CPU setup refactor
in `1cd32ba` was compared with `688fb670c87ced6b08c920e2c3527a1890218c6f`
using the **same updated driver** and compiler environment. Build one optimized
binary against an isolated baseline checkout and one against the current source, without
`-g`, sanitizers, or tracing. Warm each once, then alternate baseline/current
order across five paired samples with no concurrent builds or benchmark jobs.
The driver uses fixed iterations: 100 full-world calls, 1,000 multi-archetype
calls, 10,000 contiguous selected calls, and 1,000 disjoint selected calls.

| CPU workload | Baseline median | Refactor median |
| --- | --- | --- |
| 100,000 rows, full-world thin | 23.33 µs | 22.89 µs |
| 3,584 rows, seven matching archetypes, thin | 1.269 µs | 1.034 µs |
| Same rows, lexical closure | 1.089 µs | 0.885 µs |
| 64 selected contiguous rows in a 100k world | 69.0 ns | 18.5 ns |
| 64 selected disjoint single-row ranges in a 100k world | 690 ns | 257 ns |

The unchanged mutation controls measured 10.13 → 10.09 µs for a 64-row
add/remove chain and 107 → 98 µs for the first 512-row disjoint mutation pass.
The existing selected GPU case ran on the actual Apple M4 accelerator and
measured 276.31 → 267.52 µs. These short synthetic batches are local evidence,
not portable timing baselines or application speedup claims. Full-world row
work dominates discovery at 100k rows; small selections benefit from avoiding
matching-range allocation. Compilation is excluded from every operation timing.
The initial baseline driver build took 18.65 seconds; a repeated current build
took 1.36 seconds with local compiler caches populated. These build times are not comparable cold-compilation
measurements and establish no compilation speedup. Linux operation timings
remain unmeasured locally.

Reproduce with the current driver against both libraries:

```sh
pixi run mojo build -I /path/to/baseline/src benchmark/entity_selection_benchmark.mojo -o /tmp/larecs-selection-base
pixi run mojo build -I src benchmark/entity_selection_benchmark.mojo -o /tmp/larecs-selection-current
/tmp/larecs-selection-base
/tmp/larecs-selection-current
```

## Versus Array of Structs

The plots below show the iteration time per entity in the classical Position-Velocity example.
That is, iterate all entities with components `Position` and `Velocity`, and add velocity to position:

```mojo
position.x += velocity.x
position.y += velocity.y
```

The benchmark is performed with different amounts of "payload components",
where each of them has two `Float64` fields, just like `Position` and `Velocity`.
Further, the total number of entities is varied from 100 to 1 million.

![AoS-benchmarks](images/aos_benchmark.svg)

Note that the benchmarks run in the Github CI, 
which uses very powerful hardware.
Particularly, the processors have 256MB of cache.
On a laptop or desktop computer with typically much less cache,
Larecs🌲 will outperform AoS for everything but the smallest setups.
