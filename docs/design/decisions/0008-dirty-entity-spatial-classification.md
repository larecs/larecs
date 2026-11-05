---
id: "0008"
title: "Deferred classification of dirty spatial entities"
status: proposed
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

No decision to adopt dirty tracking has been made, and implementing it is not
planned. Retain this alternative for possible future consideration; continue
with full scans and application-controlled scan/reordering cadence under
decision 0005.

The proposed alternative is to mark entities whose classifier inputs may have
changed, deduplicate those identities, and evaluate each dirty entity once at
an explicit maintenance boundary using its final component values. Repeated
writes before maintenance would not cause repeated classification or physical
movement. Classification results would feed the row-permutation machinery;
dirty tracking would not change the structural-lock requirement.

A dense dirty-entity array with a sparse lookup indexed by entity ID could
provide amortized constant-time insertion, constant-time membership checks,
and compact iteration. Store full identities including generations, not stale
row indices; resolve current locations and filter eligibility at maintenance.
Lookup allocation, clearing, deletion handling, and policy ownership remain
undecided. No concrete data structure or public API is accepted here.

Possible marking mechanisms include:

- Explicit application marking of entities after relevant changes. This can be
  precise but makes complete marking an application responsibility.
- Conservative automatic marking of processed entities when a kernel's declared
  writes overlap classifier inputs. Such declarations identify potential writes,
  not which values actually changed.

New or newly eligible entities must also be classified. Changes to policy
configuration may invalidate every eligible entity. Reliable tracking must
cover ordinary mutation, reference-based writes, structural changes, and GPU
copy-back; intercepting only accessor setters is insufficient.

## Rationale

For N eligible entities, D distinct dirty entities, and W relevant write events,
full scans perform N classifier evaluations, per-write classification performs
W, and deferred dirty classification performs D. Sparse updates can make D much
smaller than N, while deduplication avoids repeated work for the same entity.

Tracking has its own insertion, memory, and synchronization costs. Conservative
marking may approach a full scan when kernels potentially write most entities,
and contiguous scans may then be cheaper. The initial full-scan design avoids
these costs and the risk of missing a mutation path. No performance advantage
has been measured in Larecs.

## Consequences

Adoption would add classification-invalidation state and mutation/execution
integration. Stale IDs, missing marks, changed configuration, and eligibility
changes would need explicit correctness rules. Multiple classifier policies
would also need independent invalidation or a defined shared representation.

Reducing classification to D entities does not guarantee moving only D rows:
restoring contiguous cluster ranges can displace entities whose keys did not
change. This proposal does not adopt partitioned storage or a persistent
destination-batched move queue. Any later adoption requires an acceptance
decision and comparative evidence against full scans.

## Evidence

- Accepted baseline: [decision 0005](0005-filtered-spatial-row-reordering.md)
  and [ECS-14](../requirements.md).
- Current reference-based access and entity generations:
  [entities/accessors](../../../src/larecs/entity.mojo).
- Current read/write declarations: [filters](../../../src/larecs/filter.mojo).
- Structural lock contract: [decision 0001](0001-locked-entity-selections.md).
- Planning status: [roadmap](../../roadmap.md#spatial-component-locality).
- No dirty-classification implementation, tests, or measurements exist yet.
