---
id: "0013"
title: "Cluster-local partition blocks and staging storage"
status: accepted
status_notes: Opt-in alongside deferred row reordering; functional tests and a paired CPU comparison driver are linked below.
---

# Decision 0013: Cluster-local partition blocks and staging storage

## Context

[0006](0006-partitioned-spatial-archetype-storage.md) proposes incremental
cluster-local movement beneath logical component-defined archetypes.
[0012](0012-deferred-spatial-maintenance.md) already defers classification until
an explicit unlocked boundary. Changing every query and execution backend to
use a second storage implementation would duplicate typed component lifetimes
and exact selection semantics.

## Decision

Adopt partitioned placement as an **opt-in** registration mode:
`world.register_spatial_classifier[filter](policy, partitioned=True, block_capacity=256)`.
The existing deferred row-reordering mode remains the default and comparison
control. Registration rejects nonpositive or non-power-of-two capacities before
changing registration state. A single classifier and its existing read-only
filter/configuration contract apply to both modes.

A logical archetype remains exactly one component mask and transition-graph
node. Its graph value identifies a canonical dense **staging store**. Physical
partition blocks share that node and mask; they never become graph nodes.
`HostStorage._archetypes` is an internal flat physical-store directory containing
canonical staging stores, partition blocks, and empty recycled slots.
`Archetype` remains the dense typed column/ID owner used for each store.

Each block contains only one `(logical node, UInt64 cluster key)` and at most
`block_capacity` initialized rows. Component columns are separate typed SoA
allocations with the same capacity. IDs have their own allocation. Blocks start
with capacity one and double on demand, bounded by the power-of-two row cap.
Dense clusters use multiple blocks, without a population limit. There is no
neighbor-allocation, global key traversal, or stable within-cluster order promise.

Creation and structural transitions append to canonical staging storage without
classifying. Same-composition replacements stay in their existing physical
store. At maintenance, all callbacks succeed before any placement changes.
Full invalidation classifies every eligible identity; sparse invalidation
classifies each distinct dirty eligible identity once. Pending keys commit only
after movement. Classifier failures preserve placement, committed keys, and
invalidations for retry. Component moves and compaction use the existing typed
non-raising move callbacks; allocator exhaustion is fatal as in ordinary storage.

For partition placement, changed identities move to their destination cluster.
Same-key rows already in blocks remain there unless same-cluster compaction is
needed. Source swap-removal repairs the displaced identity's row; destination
insertion repairs the transferred identity's physical-store/row location.
The boundary fills earlier blocks from later blocks **within the same logical
cluster**, leaving at most one partially occupied block per cluster. Empty
blocks release all column and ID allocations, become tombstones, and are reused
at subsequent boundaries; trailing tombstones are removed. Graph-owned indices
never move or recycle. Empty staging stores release row allocations too.

Ordinary queries, bulk mutations, CPU calls, and GPU packing/scattering traverse
physical stores through the existing mask and bounded-range machinery. Bulk
mutation snapshots each physical source, retains whole-store typed transfers,
and coalesces repeated destination result ranges. Partial selection mutation
retains its identity snapshot and resolves final physical locations. Selection
triples remain `(physical_store_index, first_row, row_count)` internally, under
the existing world-origin and structural lock contract of [0001](0001-locked-entity-selections.md).
Existing destination rows are excluded from mutation results.

`SystemContext.select_cluster[filter](key)` acquires a locked exact selection
across all matching logical archetypes and blocks. It requires partition mode,
an unlocked world, and clean maintenance. It snapshots maintained placement;
subsequent declared writes invalidate placement but do not change that selection.
Release selections/queries before maintaining. Empty clusters yield valid locked
empty selections. Selection component mutations retain their existing filtered
membership rules. Low-level raw writes still require explicit invalidation.

## Rationale

Reusing dense stores preserves typed component lifetimes, query cursor copies,
CPU binding, and GPU range packing without a second component access engine.
Canonical staging storage avoids invoking user classifiers while values are
being initialized or structurally changed, and preserves contiguous batch
creation and whole-store transfer fast paths. Small initial allocations limit
unused component capacity for singleton clusters. Reclamation bounds retained
row allocations when keys change, while stable slots protect graph references.

## Consequences

This is a choice of physical placement, not a universal performance improvement.
Sparse clusters require many allocations and per-block metadata, and ordinary
scans/CPU calls pay per-block traversal/binding cost. Structural-heavy frames
still classify all eligible rows and can temporarily hold both staging and
partition allocations. Movement may include unchanged rows during local
compaction; it is not strictly one transfer per changed key.

Active boundaries rebuild a temporary `(node,key)` directory and inspect blocks.
Sparse passes still copy the identity-capacity key cache. Complete maintenance
is therefore O(identity capacity + blocks + dirty work + compaction), not O(dirty
identities). Clean boundaries return without directory construction or compaction.
Cluster selection currently scans physical-store metadata; it has no persistent
O(1) lookup promise. Empty interior slots and list capacities retain high-water
metadata, even after their payload allocations are reclaimed. Temporary key,
directory, candidate, and selection metadata is not resident memory or RSS.

Multiple classifiers, asynchronous GPU execution, device-resident partitions,
heap-backed GPU transfers, spatial neighborhood indexing, and automatic
maintenance remain outside this decision. The existing CPU/GPU transfer and lock
rules remain unchanged. No `Cluster` component is introduced.

## Evidence

- [Requirements](../requirements.md), ECS-03, ECS-06/07, ECS-13/14, ECS-16.
- [`spatial.mojo`](../../../src/larecs/spatial.mojo),
  [`host_storage.mojo`](../../../src/larecs/host_storage.mojo), and
  [`system.mojo`](../../../src/larecs/system.mojo).
- [`partitioned_spatial_test.mojo`](../../../test/partitioned_spatial_test.mojo):
  multi-block placement, heap payloads, lifetimes, identity repair, reclamation,
  copied state, registration, errors/retries, exact selections, and bulk results.
- [`gpu_spatial_test.mojo`](../../../test/gpu_spatial_test.mojo): same ordinary
  and selected kernel on CPU/GPU, multi-block packing/scattering, dirty
  copy-back, and subsequent placement.
- [`partitioned_spatial.mojo`](../../../benchmark/partitioned_spatial.mojo) and
  [benchmark guide](../../src/guide/benchmarks.md): same-driver paired controls,
  maintenance costs, scans, complete cell frames, and capacity-derived memory.
