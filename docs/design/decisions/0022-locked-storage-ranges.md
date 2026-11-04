---
id: "0022"
title: "Locked storage ranges and independent cursors"
status: accepted
---

# Decision 0022: Locked storage ranges and independent cursors

## Context

[Decision 0001](0001-locked-entity-selections.md) replaces mutation-result
iteration in systems with exact selected kernel execution. Ordinary queries and
low-level `HostStorage` callers still need traversal without borrowing a `World`.

## Decision

`HostStorage.query` and low-level batch creation/add/remove/replacement return
`iteration.LockedEntityRange`, exposed through `HostStorage.Iterator`. Queries
remain read-only and filter-typed. Low-level mutation results retain mutable
`unsafe_get` access for setup and storage code; they are not `EntitySelection`
objects and do not offer selection mutation or execution methods.

Batch membership uses bounded `EntityRange` triples captured after mutation.
When several physical source stores append to the same destination, extend its
recorded count for every appended segment while excluding its existing prefix.
Queries share an immutable sequence of matching populated store indices and
traverse whole stores without allocating range triples. Cursor copies share
immutable membership metadata, preserve their current position, and acquire
independent structural locks. Moves transfer cursor state and the existing lock.
Exhaustion retains the lock until destruction, including for empty ranges.
Empty and exhausted stores are skipped outside the per-row fast path.
Explicit ranges are ordered relative to the supplied cursor's remaining stores,
including when that cursor has already advanced.

Storage and lock-manager origins remain tracked in the range type. Internal
row pointers reattach the tracked storage origin when producing accessors.
`HostStorage` cannot return a selection borrowing a `World` it does not own.
System logic uses `SystemContext` batch results and `EntitySelection.run`.

## Rationale

Separate membership metadata, cursor position, and guard ownership preserve
query behavior and cheap cursor copies while removing mutation-only start-index
iteration. Explicit counts prevent traversal from implicitly including a suffix
outside a batch's recorded membership. Existing migration and lifecycle engines
continue to initialize, replace, destroy, compact, and repair rows.

## Consequences

The beta concrete type `LockedWorldEntityIterator` becomes `LockedEntityRange`;
`HostStorage.Iterator` remains available, with `has_ranges` replacing the old
`has_start_indices` specialization. Inferred low-level loops continue to work.
The internal `_WorldEntityIterator` and unused start-index helper are removed.
No new entity ordering, lock bypass, or selection copying is introduced.

## Evidence

- `test/world_entity_iterator_test.mojo`: independent cursors and locks, shared
  metadata, bounded middle ranges, empty stores, growth, early and exceptional exit.
- `test/check_iteration_contracts.py`: read-only query access, noncopyable
  selections, and rejection of ranges escaping their storage origin, each with
  an allowed compiler control.
- `test/world_test.mojo`, `test/entity_selection_test.mojo`, and
  `test/gpu_entity_selection_test.mojo`: low-level compatibility and selected
  execution and mutation chains.
- `benchmark/core_smoke.mojo`, `benchmark/entity_selection_benchmark.mojo`, and
  `benchmark/migration_benchmark.mojo`: query, ordinary execution, exact selection,
  and whole-archetype mutation workloads.
- [Migration measurements](../research/entity-range-migration.md): paired PR212
  diagnostic samples and explicit concurrent-build limitations.
