---
id: "0005"
title: "Filtered spatial clustering by periodic row reordering"
status: superseded by 0012
---

# Decision 0005: Filtered spatial clustering by periodic row reordering

The full-scan-only maintenance contract below is historical. [Decision 0012](0012-deferred-spatial-maintenance.md)
retains the classifier, filter, ownership, key ordering, lock, and typed movement
rules and replaces unconditional classification with deferred invalidation.

## Context

Spatially close entities should have nearby component values in memory to
improve locality for spatial workloads. Larecs currently stores dense component
columns by component composition. Creating an archetype for every spatial cell
would mix component composition with placement and multiply storage groups.

A user-defined classifier can express spatial membership as multidimensional
cell coordinates or an encoded cluster key. `EntityAccessor` already carries a
component-access filter, which can also identify the archetypes eligible for
classification without evaluating a callback on unrelated rows.

## Decision

Register a clustering function together with an explicit component filter. The
function receives an `EntityAccessor` parameterized by that filter and computes
the entity's cluster key from declared read-only component access. The filter's
normal inclusion, exclusion, and exclusive matching rules determine eligible
archetypes. Registration must reject writable classifier access. The classifier
must not mutate the world or retain component references.

Combine multidimensional spatial classification with a dimension-independent
storage key: users may compute cell coordinates and encode them into a scalar
key, with helpers for common grid/encoding patterns. A scalar key does not imply
one-dimensional space. The concrete key type, coordinate-helper signatures,
registration API, and explicit configuration binding remain implementation
design work; this decision does not claim compiler-validated Mojo signatures.

Distinguish cluster identity from storage ordering. Equal cluster keys group
rows together; the ordering of groups determines locality between clusters.
Use a defined key ordering or explicit spatial encoding for row ordering. An
arbitrary hash is not a spatial order, numeric adjacency is not a neighbor
relationship, and an encoding must specify coordinate bounds and collision
handling. Grid helpers must use floor for negative coordinates.

Start with periodic physical row reordering **inside existing archetypes**:

- Keep archetype identity and the component-transition graph keyed by component
  composition. Clustering neither adds components nor creates spatial archetypes.
- Match each archetype against the registered filter before classifying rows.
  Skip nonmatching archetypes without invoking the function or moving their rows.
  A matching mask establishes eligibility, not that the current order is dirty;
  detecting an already ordered archetype is a separate optimization.
- At an explicit, user-triggered maintenance boundary, scan every entity in
  every matching archetype and evaluate its clustering function using current
  component values. Compute keys and a row permutation for eligible archetypes.
  Apply the same permutation to entity IDs and all active
  component columns, including columns not read by the classifier. Equal-key
  rows become contiguous within each archetype at completion.
- Update entity-to-row locations for every moved entity. Preserve component
  ownership and lifetimes through typed movement rather than assuming all
  components can be copied as raw bytes.
- Require an unlocked world before reordering. Treat row reordering as a
  structural operation even though component composition stays unchanged.
  Live queries and exact-range selections must never be reordered underneath.
- Let applications choose the maintenance cadence. Component writes, creation,
  deletion, and structural changes may degrade ordering until the next pass;
  do not trigger implicit classification or movement from a component write.
  Kernel completion and `System.update()` completion do not automatically run
  maintenance. Applications may explicitly schedule it after either boundary
  once all structural locks have been released.

Full scans are the initial classification strategy. They do not require dirty
tracking or a persistent queue of move requests between maintenance passes.
Applications control when the scan and subsequent reordering cost is incurred.
Skipping physical movement for an already ordered archetype does not skip its
classification scan. [Dirty-entity classification](0008-dirty-entity-spatial-classification.md)
is an undecided, unplanned alternative, not part of this accepted design.

The function must be deterministic for unchanged declared inputs and fixed
policy configuration. Compute classification and permutation metadata before
moving the corresponding rows, so classifier errors do not leave a partially
permuted archetype. Validate lock authorization before any movement. Define the
remaining allocation/movement error guarantees before exposing the API; this
decision does not require whole-world transactional rollback.

Registration associates each function with its own filter rather than assuming
one global position component or one global spatial classifier. This prepares
for multiple functions targeting different archetypes. Supporting multiple
registrations is future work: overlapping filters need an explicit resolution
rule before being enabled. One archetype has one physical row order; this
decision does not accept registration-order precedence, successive competing
sorts, or a composite-policy rule by implication.

## Rationale

Filtered classification combines flexible user-defined spatial models with
fast component-mask eligibility checks and checked component access. Dense row
reordering preserves the current column layout without capacity slack or
allocations per cluster. It provides a smaller first step than introducing
cluster-local partitions and permits measurement of locality benefits against
maintenance costs.

An explicit maintenance boundary fits the existing structural-lock model and
avoids intercepting writes through component references. Full scans observe
current values even when writes occurred through references or GPU copy-back,
without adding bookkeeping to ordinary mutation paths. Keeping identity and
ordering conceptually distinct avoids promising spatial locality from arbitrary
integer IDs.

## Consequences

Clustering is opt-in and a locality optimization, not a spatial-query guarantee.
Nearby entities in different archetypes still occupy separate storage. Nearby
entities across cell boundaries need not have adjacent rows. Exact neighbor
queries require their own cell enumeration/indexing and distance checks;
physical order can lag behind positions between maintenance passes.

Entity identities and ordinary component-query membership remain unchanged.
No stable row order or tie order is introduced. Existing references cannot
survive maintenance, and selections must be released before maintenance begins,
as required by [decision 0001](0001-locked-entity-selections.md).

The existing GPU path packs host spans into device columns under
[decision 0002](0002-gpu-system-execution.md). Reordering must remain compatible
with CPU/GPU execution and copy-back; it does not introduce GPU classifier
execution, a cluster-aware kernel API, device residency, or device-side neighbor
lookup.

Performance is unmeasured. Benchmark complete workloads, including classification
and movement of all columns, rather than measuring only the spatial kernel.
Periodic reordering may be unsuitable for wide archetypes or highly mobile
entities. [Partitioned storage](0006-partitioned-spatial-archetype-storage.md)
remains an undecided alternative. A special placement component is rejected in
[decision 0007](0007-special-cluster-component.md).

## Evidence

- Accepted requirements: [ECS-12 through ECS-15](../requirements.md).
- Current storage and movement foundations: [archetypes](../../../src/larecs/archetype.mojo),
  [host storage](../../../src/larecs/host_storage.mojo), and
  [entity locations/accessors](../../../src/larecs/entity.mojo).
- Existing mask matching and access declarations: [filters](../../../src/larecs/filter.mojo).
- Lock and exact-range contract: [decision 0001](0001-locked-entity-selections.md).
- Implementation and validation work: [roadmap](../../roadmap.md#spatial-component-locality).
- [Decision 0009](0009-typed-row-permutation-foundation.md) implements the internal
  typed permutation foundation with lock/location and lifecycle tests and a
  movement-only benchmark. [Decision 0010](0010-spatial-classifier-maintenance.md)
  implements classifier registration and explicit maintenance; complete spatial
  workload measurements remain pending.
