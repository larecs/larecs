---
id: "0020"
title: "Partitioned resource writes"
status: proposed
status_notes: |
  Proposal from integrating decision 0019 into Tree-D. Not implemented. API
  expressions are illustrative, not compilable Mojo. Measurements come from an
  out-of-tree prototype that reproduces the dispatch by hand.
---

# Decision 0020: Partitioned resource writes

## Context

[Decision 0019](0019-threaded-host-execution.md) parallelizes kernels whose rows
write only their own components. Many simulation systems instead *scatter*: each
row writes into a shared, spatially indexed resource. Tree-D's
`FillLeafDistributionSystem` is the motivating case. Every tree inserts its crown
into a 1 m grid of fixed-capacity ring buffers (`LeafDistribution`), touching all
cells within its crown radius; the leaf-layer kernel then reads the grid.

Threading that kernel under decision 0019 fails on three counts:

1. **Writable resources are rejected.** The grid is the kernel's output, so it
   needs write access, which threaded runs refuse.
2. **Unspecified chunk order breaks reproducibility.** Even with atomic cell
   counters (decision 0016), concurrent chunks would append to a cell in
   scheduling order. The ring buffer keeps insertion order, the ray integral
   sums slots in that order, and a full cell overwrites a different sample.
   Results would differ from sequential execution and between runs.
3. **Private copies do not fit.** A per-worker grid merged in chunk order would
   be deterministic, but one grid holds 16 samples × 4 floats per square metre
   (4.3 GB for a 4.1 km plot), so a copy per worker is unaffordable.

Tree-D's leaf-layer kernel now runs threaded (bitwise identical to sequential),
which leaves the grid fill as the serial remainder of a light update; see
[Evidence](#evidence).

## Decision

Propose an opt-in **partitioned write** resource access for threaded host runs:
the resource, not the row range, is split among workers.

### Model

An adapter splits a writable source into `P` disjoint partitions, for example
x-strips of a grid. A threaded run with a partitioned write dispatches one job
per partition. Each job visits **every** matching row, in the same order as
sequential execution, with a mutable view of its own partition only. Writes are
clipped to the partition: the view exposes its bounds, and view methods ignore
or reject out-of-partition elements.

Every element is therefore written by exactly one job, in sequential row order.
If a row's effect on an element depends only on that element's previous state
(appends, accumulations, overwrites), the result is bitwise identical to
sequential execution, independent of worker count and scheduling. No atomics
are required.

### Illustrative API

```mojo
struct LeafGridAdapter(PartitionedWriteAdapter):
    comptime Source = LeafDistribution
    comptime PartitionView = LeafStripView   # TrivialRegisterPassable

    @staticmethod
    def partition_count(source: Self.Source, workers: Int) -> Int: ...

    @staticmethod
    def bind_partition(
        mut source: Self.Source, index: Int, count: Int
    ) raises -> Self.PartitionView: ...

    @staticmethod
    def finish(mut source: Self.Source, count: Int) raises: ...  # e.g. max height


def fill(rows: KernelContext[
    Filter().read[Position, Height, CrownDimensions, CrownBaseFunction](),
    Resources().read[SpeciesOptics]().partitioned_write[LeafDistribution](),
]):
    ref strip = rows.resources.get[LeafDistribution]()   # LeafStripView
    for tree in rows:                                    # all rows, sequential order
        strip.add_tree(...)                              # writes only owned cells


context.run[fill, threaded=True]()
```

### Semantics

- **Components are read-only.** Every job visits every row, so component writes
  would race. Reject `write`/`include` access to components in partitioned runs.
- **One partitioned write per run.** Further resources follow decision 0019
  (read-only plain values or `KernelView` adapters).
- **Sequential fallback** (one worker, or below the row cutoff) binds a single
  partition covering the whole source. That is today's sequential kernel.
- **Binding and lifetime** follow decision 0018/0019: validate and bind all
  partitions on the caller before dispatch, keep the source leased until join,
  and call `finish` after join to combine partition-local reductions, such as
  a maximum height.
- **Adapter contract:** partitions must be disjoint in memory, and a partition
  view must not read another partition's elements. Larecs cannot prove this;
  the adapter author guarantees it, as with concurrent reads in decision 0019.

### Row scanning cost and binning

A naïve job scans all rows, so bounds checks cost `rows × P`. Two refinements
keep this small:

1. **Footprint binning.** An optional adapter function
   `partition_range(row) -> (first, last)` lets Larecs bin rows by partition in a
   threaded pre-pass and give each job only the rows that intersect it, still in
   row order. Large footprints appear in several bins.
2. **Spatial storage.** With cluster-local partitions (decisions 0006/0014),
   rows of one region are already contiguous, and binning reduces to selecting
   clusters.

Neither changes the result; both reduce the scan overhead.

## Alternatives

| Alternative | Deterministic | Extra memory | Notes |
| --- | --- | --- | --- |
| Partitioned writes (this proposal) | Yes, equals sequential | None | Host only; per-row scan or binning pass |
| Atomic scatter through decision 0016 bindings | No: insertion order depends on scheduling | None | Also works on the device; needs tolerance-based validation and overflow policy |
| Per-worker private resources, ordered merge | Yes with chunk-ordered merge | One copy per worker | Infeasible for large grids |
| Gather by cell (iterate cells, look up covering rows) | Yes | Spatial index | Cells are not entities; needs a separate index and kernel shape |

Atomic scatter remains the natural follow-up for **device** fills once
decision 0016 bindings exist. Partitioned writes are the smaller step and keep
host results exactly reproducible, which Tree-D's benchmark validation relies on.

## Related findings from the integration

These are independent of partitioned writes and smaller in scope:

- **Declared plain values.** Reflection cannot inspect `StaticTuple` or
  `InlineArray`, so threaded runs rejected Tree-D's leaf-layer output component.
  Branch `feat/declared-plain-values` adds an opt-in `PlainValue` marker.
- **Per-run row cutoff.** `min_parallel_rows` is world-wide. Tree-D needed 1024
  instead of 65,536 because each row traces rays, while trivial kernels in the
  same world would want the larger default. A per-run override or cost hint,
  such as `run[kernel, threaded=True, min_parallel_rows=1024]`, avoids choosing
  one value for every kernel.
- **Configuration after construction.** The worker budget is fixed when the
  world is created, so Tree-D had to thread `cpu_threads` through model
  construction and configuration loading. Replacing the configuration on an
  idle world (rejected while executing) would let applications select threads
  later without rebuilding the world.

## Rationale

Partitioning the output, rather than the rows, is the only option here that
preserves sequential results without atomics or extra memory. Re-scanning rows
is cheap next to the per-element work of typical scatter kernels, and binning
removes most of it. The sequential fallback is exactly today's kernel, so
adopting the access mode cannot change single-threaded behavior.

## Consequences

- Adds a new adapter trait and resource access mode. Kernels must clip writes,
  so existing scatter code needs a partition-aware entry point; Tree-D's
  `add_tree` already loops over cell columns and only needs column bounds.
- Kernels must be written so that each element's update depends only on that
  element's prior state; the adapter contract documents this.
- Species or other per-row lookups must be available as threaded read resources.
  Tree-D currently reads a host `Dict` of species parameters and would need a
  pointer-free table or a per-row component.

## Evidence

Prototype: Tree-D's grid fill with hand-written x-strip partitions, one strip
per worker, each scanning all trees in row order and clipping columns. It
reproduces the sequential grid bitwise for 2 to 16 workers.

Measured on an AMD Ryzen 7 PRO 5850U (8 cores, 16 threads, laptop with
background load), Mojo 1.0, 300 trees/ha, sample capacity 16, 1 m cells. Best
of five; the clear is a per-strip `memset_zero`.

| Plot | Trees | Sequential clear + insert | 2 workers | 4 workers | 8 workers | 16 workers |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1500 m | 67,500 | 19 + 67 ms | 1.12× | 1.14× | 1.13× | 0.74× |
| 4100 m | 504,299 | 155 + 554 ms | 1.20× | 1.50× | 1.59× | 1.16× |

Insertion scales to about 1.9× on 8 workers at 4100 m. Clearing the 4.3 GB
grid is memory-bandwidth bound and does not scale, and it already accounts for a
fifth of the sequential fill. On this machine, partitioned writes therefore
help only for large plots. Tree-D can gain more by touching less memory, for
example by resetting only occupied cells or using a smaller sample capacity,
than from threads alone. Server CPUs with more memory channels should scale
better, but that is not measured here.

For context, the threaded leaf-layer rays in the same benchmark (Tree-D
`LightBenchmark`, `rays` stage, 500–1500 m) reach 1.7×, 2.7× and 3.3× on 2, 4
and 8 threads. A light update (fill plus rays) reaches 1.7×, 2.5× and 2.9×; at
1500 m on 8 threads the serial fill is about 17 % of the light update. A full
Tree-D simulation step reaches 1.35×, 1.62× and 1.73×, because other systems
also stay sequential.
