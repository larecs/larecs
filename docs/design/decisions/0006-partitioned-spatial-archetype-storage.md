---
id: "0006"
title: "Partitioned spatial storage beneath archetypes"
status: accepted
status_notes: Adopted as an opt-in mode with the concrete layout and limits in decision 0013.
---

# Decision 0006: Partitioned spatial storage beneath archetypes

## Context

[Decision 0005](0005-filtered-spatial-row-reordering.md) accepts periodic row
reordering within archetypes as the initial spatial-locality design. Frequent
reordering can move substantial component data. Persistent cluster-local
partitions could instead support incremental movement and direct cluster lookup.

## Decision

Adopt partitioned storage as an opt-in alternative to row reordering.
[Decision 0013](0013-cluster-local-partition-blocks.md) resolves the layout,
allocation, reclamation, staging, movement, exact membership, and execution
contracts. The following describes the original architectural motivation.

Keep logical archetypes keyed by component composition, but store their rows in
partitions keyed by cluster identity. Each partition owns one or more dense
blocks of component columns and entity IDs. Multiple blocks accommodate a dense
cluster without imposing a fixed maximum cluster population.

At an explicit structural maintenance boundary, transfer entities whose keys
changed into destination partitions. Compact source blocks within the same
cluster and update locations for transferred and compacted entities. Ordinary
component queries traverse every matching archetype's partitions and blocks.
Partitions do not become separate nodes in the component-transition graph.

The filtered classifier model from decision 0005 could supply partition keys.
It does not settle block capacity, allocation placement, partition reclamation,
cross-archetype indexing, overlap between classifier filters, or whether physical
movement should remain periodic or become more incremental.

## Rationale

Persistent partitions could preserve grouping through local swap-removal and
move only entities crossing cluster boundaries. They could also expose ranges
for cluster-local processing without rebuilding equal-key ranges after each pass.

However, equal-key grouping does not guarantee that neighboring clusters have
nearby allocations. Allocation or traversal ordering would need separate design
and evidence. Sparse clusters can create many small blocks or unused capacity,
and full-archetype scans gain traversal overhead.

## Consequences

Adoption would affect entity locations, row accessors, mutation destinations,
query traversal, exact-range selections, and CPU/GPU range preparation. Current
selection triples identify an archetype and a contiguous row interval; a block
model needs a representation preserving exact membership and structural locks.
It must preserve valid component lifetimes and efficient batch operations.

Compare maintenance cost, memory overhead, allocation count, block occupancy,
ordinary scan throughput, and complete spatial-workload time against deferred
row reordering. Keep the existing default: workload-specific tradeoffs do not
justify automatically switching registered worlds to partitions.

## Evidence

- Accepted starting point: [decision 0005](0005-filtered-spatial-row-reordering.md).
- Current layout: [architecture](../architecture.md) and
  [archetypes](../../../src/larecs/archetype.mojo).
- Exact-range constraints: [decision 0001](0001-locked-entity-selections.md).
- Evaluation work: [roadmap](../../roadmap.md#spatial-component-locality).
- Concrete adopted design and implementation evidence: [decision 0013](0013-cluster-local-partition-blocks.md).
