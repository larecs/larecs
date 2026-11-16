---
id: "0014"
title: "One growable store per logical cluster"
status: accepted
status_notes: CPU tests, guide doctests, and same-driver Linux comparisons passed; GPU execution was skipped because this runner has no accelerator.
---

# Decision 0014: One growable store per logical cluster

## Context

[Decision 0013](0013-cluster-local-partition-blocks.md) split each logical
cluster into capacity-limited blocks. Clustering and chunking both control
locality, but applications can choose cluster granularity through classifier
configuration. Extra blocks add allocations, metadata, and range setup even
when all their rows have the same key. The historical CPU measurements in the
[benchmark guide](../../src/guide/benchmarks.md#partitioned-storage-comparison)
show workload-dependent scan and memory costs; they do not establish the
performance of an unbounded layout.

## Decision

Supersede decision 0013's bounded-block layout with exactly one growable dense
store per `(logical archetype node, UInt64 cluster key)` after maintenance.
Register with `world.register_spatial_classifier[filter](policy, partitioned=True)`;
remove `block_capacity`, its validation, and the default 256-row cap.

Each store starts at one row and doubles component-column and entity-ID capacity
on demand. Each component remains contiguous within that store; separate stores
need not have adjacent allocations. There is no fixed cluster population limit,
stable row order, or global key-order guarantee. Nonempty stores retain grown
capacity; empty cluster stores release allocations and recycle directory slots.

Retain staging for creation and structural transitions, deferred classification,
classification failure/retry guarantees, typed row transfer, source swap-removal,
location repair, structural locks, and exact cluster selections. Cross-block
compaction is removed. Unchanged-key rows stay in their store, although growing
the store can relocate all its columns. Ordinary queries and CPU/GPU execution
continue to traverse matching physical ranges with existing transfer rules.
Row reordering remains the default; partitioning remains opt-in.

## Rationale

One store gives each cluster one contiguous array per component and avoids a
second user-configured partitioning scale. Classifiers can adjust cell size or
otherwise produce finer keys when smaller clusters are desirable. Reusing the
dense typed store preserves the existing ownership and execution machinery.

## Consequences

Callers must remove the `block_capacity` argument. Dense clusters no longer pay
for block switches or same-cluster redistribution. Destination growth can move
more than 256 existing rows and retain spare capacity. Sparse clusters still
require separate allocations and metadata, so this change alone does not resolve
sparse-world scan costs. Active maintenance still copies identity-capacity keys
and rebuilds the cluster directory; selection scans physical-store metadata.
Historical bounded-block timings remain explicitly labeled in the guide; new
performance claims require fresh measurements on matching hardware/compiler.

## Evidence

- [Requirements](../requirements.md): ECS-03, ECS-13, ECS-16.
- [`spatial.mojo`](../../../src/larecs/spatial.mojo): one destination per cluster,
  geometric growth, typed transfers, and empty-store reclamation.
- [`partitioned_spatial_test.mojo`](../../../test/partitioned_spatial_test.mojo):
  uniqueness, staged growth to 1,200 rows, copying, merging/splitting,
  exact membership, payload/location preservation, lifetimes, and retries.
- [`gpu_spatial_test.mojo`](../../../test/gpu_spatial_test.mojo): ordinary and
  selected CPU/GPU paths with clusters larger than the old limit. GPU execution
  requires available hardware; skipped paths are not hardware validation.
- [`partitioned_spatial.mojo`](../../../benchmark/partitioned_spatial.mojo):
  unchanged-layout query/CPU controls, maintenance, complete frames, and memory
  reporting for identical dense, uniform, and singleton distributions.
