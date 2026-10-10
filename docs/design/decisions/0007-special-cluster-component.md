---
id: "0007"
title: "Special Cluster component for spatial placement"
status: rejected
---

# Decision 0007: Special Cluster component for spatial placement

## Context

An alternative to a classifier is a special `Cluster` component whose value
determines physical placement. This would make spatial membership writable
through ordinary component access, but would couple value mutation to structural
storage changes.

## Decision

The proposal was to introduce a special built-in `Cluster` component that users
could add to an entity. Its value would determine spatial membership, grouping
entities with equal values together in storage in addition to grouping them by
component composition. Changing the value would require updating the entity's
physical placement, either immediately or at a deferred maintenance boundary.

Reject this proposal in favor of the registered, explicitly filtered clustering
function accepted in [decision 0005](0005-filtered-spatial-row-reordering.md).

Applications may still define ordinary components holding region IDs or cached
cell coordinates and read them in a clustering function. Those components have
normal component semantics: their writes do not implicitly move rows, and they
are not automatically kept consistent with positions by Larecs.

## Rationale

- Position-derived membership would duplicate information. A stored cluster
  value can disagree with position, requiring extra writes and synchronization
  rules without eliminating classification or reordering work.
- Ordinary writable component references cannot safely trigger immediate row
  movement during kernel/query iteration. Special handling would conflict with
  structural locks and exact-range selections. Deferred handling would still
  require the explicit maintenance boundary already accepted for classifiers.
- A mandatory component adds storage and changes component composition merely
  to request a layout optimization. Filtered registration expresses eligibility
  without requiring an extra component on every spatial entity.
- One special cluster value does not express multiple independent spatial
  policies. Classifier-specific filters provide a clearer foundation for future
  multiple registrations, whose overlap rules still need design.
- Explicit region membership remains useful application data, but that does not
  require a special library component or exceptional write semantics.

Grouping by component values would also require the same choices about key
ordering, maintenance cadence, and fragmentation as the other approaches. It
does not itself guarantee that nearby clusters occupy nearby memory.

## Consequences

Spatial placement stays separate from ordinary component semantics. Applications
can derive membership directly from position or choose to maintain their own
cached membership component. They remain responsible for keeping such cached
data consistent. This decision does not prohibit ordinary user-defined `Cluster`
types and does not decide a general-purpose shared-component feature.

## Evidence

- Accepted classifier and maintenance model: [decision 0005](0005-filtered-spatial-row-reordering.md).
- Requirement reflecting the chosen alternative: [ECS-15](../requirements.md).
- Writable filtered access: [EntityAccessor](../../../src/larecs/entity.mojo).
- Structural lock and membership constraints: [decision 0001](0001-locked-entity-selections.md).
- This records an architectural rejection, not a measured performance comparison.
