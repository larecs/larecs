---
id: "0009"
title: "Typed row permutation foundation"
status: accepted
status_notes: Internal storage foundation; public classifier registration and maintenance are implemented separately under decision 0010.
---

# Decision 0009: Typed row permutation foundation

## Context

[Decision 0005](0005-filtered-spatial-row-reordering.md) requires all active
columns and entity IDs to share a permutation without breaking component
ownership or entity locations. Storage already erases component lifecycle
operations behind typed callbacks. This first implementation step supplies
movement independently of the future classifier and registration API.

## Decision

Use an internal destination-to-source permutation: entry `i` is the old row
that belongs at new row `i`. `HostStorage._reorder_archetype_rows` requires an
unlocked world, checks the archetype index, delegates to `Archetype._reorder_rows`,
and repairs entity locations before returning. Callers must use the storage
entry point for world-owned archetypes; the lower-level archetype method cannot
check the owner's locks or repair its location table.

Validate length, bounds, and uniqueness and build a complete swap plan before
moving any rows. Apply the plan with per-column typed move callbacks and the
same entity-ID swaps. Skip fixed rows; an identity permutation performs no
component moves. No components are copied or destroyed during permutation.
Composition masks, archetype graph nodes, entity IDs, and generations are
preserved.

Recoverable validation and lock errors leave storage unchanged. Scratch
allocation finishes before movement; typed movement and location repair have
no recoverable error path. The permutation code allocates no buffers during
movement; user-defined component move constructors retain their normal
behavior and may allocate internally. Process-fatal allocation
failure, assertion failure, or termination inside a component lifecycle method
is not covered by rollback. This defines the movement primitive's guarantee;
classifier error handling remains work for the maintenance layer, which must
compute keys and permutations before calling it.

## Rationale

An in-place swap plan retains column allocations and capacity and reuses
existing type-erased lifecycle infrastructure. Typed take/write operations
support heap-owned components and custom move constructors. Precomputing the
plan keeps malformed input and scratch allocation outside the movement phase.

## Consequences

Planning takes O(rows) time and three temporary integer arrays. Movement takes
O(rows × registered component types) mask checks and at most rows minus one
swaps per active column; location repair takes O(rows). Columns keep their base
addresses, but references to logical entities cannot survive reordering.

This is an internal primitive, not a public spatial API. It does not classify,
choose a key ordering, register policies, or trigger maintenance. Full spatial
workload and CPU/GPU compatibility validation remain on the roadmap. The
permutation benchmark measures movement and metadata costs, not spatial benefit.

## Evidence

- [Implementation](../../../src/larecs/archetype.mojo) and
  [lock/location integration](../../../src/larecs/host_storage.mojo).
- [Correctness and lifecycle tests](../../../test/host_storage_lifecycle_test.mojo).
- [Permutation-only benchmark](../../../benchmark/row_reordering_benchmark.mojo).
- [Remaining spatial work](../../roadmap.md#spatial-component-locality).

A preliminary standalone run on Apple M4 with Mojo 1.0.0 (`ed45d567`),
using this worktree based on `78c6e9f`, measured 1.623 ms per reversal and
1.203 ms per identity pass for 100,000 rows containing `Int` and
`SIMD[float32, 16]` (72 component bytes per row). Each case used one fixed
20-iteration batch via
`pixi run mojo run -I src benchmark/row_reordering_benchmark.mojo`, with no
concurrent compilation. Setup and construction of the input mapping are
excluded; validation, swap-plan allocation, movement, and location repair are
included. Reversal exchanges 50,000 pairs on every pass; identity moves none.
These are preliminary primitive costs, not a baseline comparison or evidence
of spatial workload speedup.

Validation: all 17 host-storage lifecycle tests passed with AddressSanitizer.
The complete `pixi run tests test` run passed 18 test files and failed to
compile six GPU-bearing files with `Metal Compiler failed to compile metallib`.
All six failures reproduced when compiling the untouched `78c6e9f` source and
tests from an isolated temporary directory, so GPU validation remains blocked
by a baseline compiler/environment failure. API-doc generation passed. Guide
doctests did not run because `docs/test` was absent.
