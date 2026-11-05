---
id: "0008"
title: "Deferred classification of dirty spatial entities"
status: accepted
---

# Decision 0008: Deferred classification of dirty spatial entities

## Context

[Decision 0005](0005-filtered-spatial-row-reordering.md) uses full scans of
matching archetypes during user-triggered maintenance. If only a small subset
of entities changes classifier inputs, scanning every eligible entity may spend
most classification work on unchanged data.

Evaluating the classifier after each input write avoids a full scan but can
repeat classification for the same entity and observe intermediate values.
Deferring classification does not inherently require a full scan if changed
entities can be tracked reliably.

## Decision

Adopt deferred classification at explicit maintenance boundaries. Mark potentially
changed inputs, deduplicate full entity identities, and classify each dirty
eligible entity once using its final values. Registration and structural changes
request a full rebuild. Classification never happens during mutation or kernel
completion, and row permutations still require an unlocked world.

[Decision 0012](0012-deferred-spatial-maintenance.md) defines the concrete owned
state, automatic invalidation paths, explicit escape hatches, failure guarantees,
and measured tradeoffs. It supersedes the full-scan-only portions of decisions
0005 and 0010 while retaining their filter, ownership, key, and permutation rules.

## Rationale

For N eligible entities, D distinct dirty entities, and W relevant write events,
full scans perform N classifier evaluations, per-write classification performs
W, and deferred dirty classification performs D. Sparse updates can make D much
smaller than N, while deduplication avoids repeated work for the same entity.

Tracking has its own insertion, memory, and synchronization costs. Conservative
marking may approach a full scan when kernels potentially write most entities,
and contiguous scans may then be cheaper. The initial full-scan design avoids
these costs and the risk of missing a mutation path. Comparative synthetic measurements are recorded in decision 0012; application
benefit remains workload-dependent.

## Consequences

The implementation adds world-owned key and invalidation state. Conservative
reference and range marking can include entities whose values did not change.
Structural mutations currently rebuild all eligible keys rather than attempting
fine-grained transition tracking. Multiple policies remain unsupported.

Reducing classification to D entities does not guarantee moving only D rows:
restoring contiguous cluster ranges can displace entities whose keys did not
change. This proposal does not adopt partitioned storage or a persistent
destination-batched move queue. The implementation retains archetype row reordering rather than adopting either
alternative.

## Evidence

- Historical full-scan baseline: [decision 0005](0005-filtered-spatial-row-reordering.md)
  and [ECS-14](../requirements.md).
- Current reference-based access and entity generations:
  [entities/accessors](../../../src/larecs/entity.mojo).
- Current read/write declarations: [filters](../../../src/larecs/filter.mojo).
- Structural lock contract: [decision 0001](0001-locked-entity-selections.md).
- Planning status: [roadmap](../../roadmap.md#spatial-component-locality).
- [Implementation and comparative evidence](0012-deferred-spatial-maintenance.md).
