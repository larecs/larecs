---
id: "0010"
title: "Owned spatial classifiers and explicit maintenance"
status: accepted
status_notes: One host classifier per world; complete spatial workload benefit remains unmeasured.
---

# Decision 0010: Owned spatial classifiers and explicit maintenance

## Context

[Decision 0005](0005-filtered-spatial-row-reordering.md) accepts filtered,
explicit spatial clustering. [Decision 0009](0009-typed-row-permutation-foundation.md)
provides typed row movement. Registration, configuration, scalar key ordering,
coordinate encoding, and classifier error handling need concrete Mojo APIs.

## Decision

`World.register_spatial_classifier[filter](classifier)` owns a copyable
`SpatialClassifier` value. Its fields bind configuration explicitly; world
copies copy that value and world moves transfer it. The policy declares
`Accessor = EntityAccessor[filter]` and implements
`classify(self, entity: Self.Accessor) raises -> UInt64`. Registration checks
accessor/filter agreement, rejects writable filters and unknown world component
types at compile time, and requires unlocked storage. Only one registration
is supported; a second registration raises without replacing the first,
including when filters are disjoint. Multiple policies and overlap resolution
remain future work.

Keys are both cluster identities and ascending unsigned ordering keys: equal
keys group together; distinct cells must have distinct keys when they represent
distinct clusters. Arbitrary hashes do not establish spatial locality. Tie
order is not a public guarantee. Classifiers must be deterministic for unchanged
declared inputs and configuration, must not mutate the world, and must not
retain accessors or component references. Read-only access is compiler checked;
the reference-retention and determinism rules are application obligations,
consistent with the existing untracked `EntityAccessor` contract.

`grid_cell(position, cell_size)` uses floor, requires finite inputs and a
strictly positive finite size, and rejects cells outside [-1048576, 1048575].
`morton_key_3d(x, y, z=0)` biases each signed 21-bit coordinate by 1048576
and interleaves x/y/z bits into a 63-bit `UInt64`. This encoding is injective
within its bounds: it neither clamps, wraps, nor hashes out-of-range cells.
Using z=0 gives a planar encoding. Adjacency in key order does not imply spatial
neighborhood, and adjacent cells are not guaranteed adjacent storage rows.
Applications may supply another encoding over the full UInt64 key range.

`World.maintain_spatial()` requires unlocked storage, even without a registered
policy. With no policy it is a no-op. Otherwise it matches the normal filter
inclusion/exclusion/exclusive rules, classifies every eligible row using
current host values, and orders rows independently within each existing
archetype. It builds keys and destination-to-source permutations for **all**
eligible archetypes before moving any rows. Classification runs under a
structural lock, released on success and failure; reentrant structural mutation
and nested maintenance are rejected. Already ordered and empty archetypes
need no movement, but ordered archetypes are still classified on every pass.

Classifier errors preserve all archetype row orders and propagate their
original `Error` through `LarecsError`. Metadata allocation during classification
and sorting precedes movement. Applying each permutation uses decision 0009's
prevalidated typed swaps and location repair. Scratch allocation for each
archetype's movement plan occurs before moving that archetype, rather than
being preallocated for the entire world. Recoverable classifier/lock errors
have no partial movement; process-fatal allocation or lifecycle failures do not
promise rollback. No whole-world rollback is promised for fatal failures in a
later archetype. Entity IDs, generations, composition, and membership remain
unchanged; references and queries cannot survive maintenance.

No ordinary write, entity mutation, kernel completion, system completion, or
GPU copy-back triggers maintenance. Systems may explicitly call
`context.world[].maintain_spatial()` after releasing all queries/selections.
GPU execution continues to pack the current host row order and scatter writes
back; classification remains on the host.

## Rationale

An owned policy struct makes configuration and copy/move behavior explicit,
avoids borrowed closure capture lifetime ambiguity, and uses the same
`UnsafeBox` type-erasure infrastructure as scheduler systems. An explicit filter
and checked associated accessor type express read-only eligibility in Mojo 1.0,
whose traits cannot carry a parameterized Filter value directly.

One UInt64 key gives a simple total ordering without requiring type-erased
comparators. Checked Morton encoding supplies a common multidimensional spatial
order without conflating a hash with locality. Sorting row indices with a
bottom-up merge sort takes O(n log n) and does not move component values.
Computing all classification plans first strengthens failure behavior without
requiring rollback of typed component moves.

## Consequences

This adds an opt-in public API without changing ordinary execution or mutation
paths. Each world stores an optional policy and maintenance adapter. Maintenance
uses O(eligible rows) temporary metadata (keys, row indices, merge scratch, and
pending permutations), plus the active archetype's movement-plan scratch from
0009. Movement cost grows with all active component columns, not just classifier
inputs. The application chooses the cadence and pays for full scans each time.

The classifier model implements ECS-12 through ECS-15 for one policy. It does
not provide a neighbor-query index, GPU classifier execution, automatic dirty
tracking, multiple registrations, or evidence of net spatial workload speedup.

## Evidence

- [Registration](../../../src/larecs/world.mojo),
  [classification and helpers](../../../src/larecs/spatial.mojo).
- [Filter, coordinate, scan, failure, copy, and lock tests](../../../test/spatial_test.mojo).
- [Nontrivial component lifetime tests](../../../test/host_storage_lifecycle_test.mojo).
- [CPU/GPU execution and copy-back tests](../../../test/gpu_spatial_test.mojo).
- [User guide](../../src/guide/spatial_clustering.md).
- [Complete maintenance cost benchmark](../../../benchmark/spatial_benchmark.mojo),
  including classification, sorting, all-column movement, and location repair.
  These microbenchmarks do not establish net spatial-workload benefit.
- [Remaining measurements and multi-policy design](../../roadmap.md#spatial-component-locality).
