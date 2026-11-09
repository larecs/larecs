+++
type = "docs"
title = "Queries, selections, and ranges"
weight = 3
+++

We discover stores by component masks, then traverse bounded row ranges.
{{< api Filter >}} carries compile-time membership and access declarations;
its include/exclude masks match physical stores. Excluded types constrain
membership without supplying a component pointer. Read/write declarations
also determine accessor permissions, invalidation, and device transfers.

## Guard ownership and cursor ownership

{{< api HostStorage.query query >}} returns a read-only
{{< api LockedEntityRange >}}. The range owns a structural `LockGuard` and a
cursor. Copies share immutable store-index/range metadata through
`ArcPointer`, copy cursor positions independently, and acquire distinct lock
bits. Exhaustion stops a cursor; it does not release its guard. Destroying
one copy leaves the other copy's guard intact.

The lock manager uses a fixed 256-bit lock set. Acquisition raises when those
bits are exhausted; copying a guard aborts because `Copyable` cannot report
an error. Moving transfers the existing bit. The guard only rejects structural
changes that would invalidate borrowed rows. It provides no cross-thread
exclusion or component-data synchronization.

| Representation | Ownership and purpose |
| --- | --- |
| `Entity` | Copyable stable identity; no lock or row borrow. |
| Query row accessor | Temporary read-only reference into a guarded store; cannot outlive its range. |
| `EntityRange` | Store index, first row, and row count; plain metadata owns no lock. |
| `LockedEntityRange` | Storage borrow and independent guard/cursor, including low-level batch membership. |
| `EntitySelection` | Movable, noncopyable exact membership plus one system-level structural guard. |
| Kernel row accessor | Invocation-local column pointers and row offset; no stable entity ID. |

## Exact batch membership

{{< api EntitySelection >}} retains triples of physical-store index, first
row, and row count. Structural operations update those triples in place.
A partial source range can move to a different store; the selection follows
the affected rows and excludes preexisting destination rows. Kernel execution
intersects that membership with the kernel's filter.

Selections authorize their own mutations only when their guard is the sole
active structural lock. Another query or selection prevents that mutation;
nesting does not grant access through the other guard. Release, destruction,
or context-manager exit releases the selection lock, including error exits.

Low-level `HostStorage` batch results use `LockedEntityRange`, rather than
the system-level selection. Both retain bounded membership: extending a
destination store must not make an older batch suddenly include unrelated
rows. Sharing metadata avoids copying whole range lists when copying cursors;
it does not share cursor position or authorize mutation.

## From membership to work

A host context offsets its column pointers to the selected range's first row
and numbers local rows from zero. Threaded chunks repeat that rebasing.
Device packing concatenates selected spans and scatters outputs to their
original locations. Thus `particle.idx` is a context-local offset, never a
stable handle or a full-world sequence number. See [work mapping](../execution)
and [transfers](../transfers).

Implementation: {{< source "iteration.mojo" >}},
{{< source "lock.mojo" >}}, {{< source "system.mojo" >}}.
Evidence: {{< repo "test/world_entity_iterator_test.mojo" >}},
{{< repo "test/entity_selection_test.mojo" >}},
{{< repo "test/check_iteration_contracts.py" >}};
{{< repo "docs/design/decisions/0024-locked-storage-ranges.md" "decision 0024" >}}
records the range contract.
