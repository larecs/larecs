+++
type = "docs"
title = "Synchronization internals"
weight = 7
+++

{{< api sync.AtomicValue AtomicValue >}} and
{{< api sync.Synchronized Synchronized >}} own target-local state.
Their copyable views retain one protection identity; owners and acquired guards
are noncopyable. These standalone primitives do not supply `KernelContext.sync`,
collection domains, automatic transfer bindings, or deferred retries.
Those parts of accepted decision 0016 are unimplemented; decision 0017 remains
proposed. [Coordinate shared writes](../../../guide/execution/shared_writes)
explains available application patterns.

## Scalar operations and scope

`AtomicView` points to aligned `UInt32` or `Int32` storage accessed only
atomically. Add/subtract wrap at the scalar width and return the previous value.
Strong compare-exchange returns success and the observed value, using relaxed
failure ordering. Read views permit loads only. Scalar operations default to
relaxed ordering: counters do not publish adjacent ordinary payload writes.

The implementation selects CPU-wide scope, NVIDIA `device` scope, or AMD
`agent` scope. Loads accept acquire and stores accept release. Supported
read-modify-write operations also accept acquire, release, and acquire-release.
Apple GPU support is limited to relaxed add/subtract and relaxed/acquire loads
or relaxed/release stores. Strong CAS, ordered updates, and guards are rejected
there. Release stores and acquire loads supply the separately verified Apple
publication path; a compile probe alone would not prove hardware ordering.

## One state word per protected payload

`Synchronized` stores a payload and one initialized `UInt32` state word.
Zero means unlocked, the high bit (`0x80000000`) means one writer, and the
remaining bits count readers up to `0x7fffffff`. Every view of an overlapping
payload must use the same state word.

`try_read` loads state, rejects writer/saturation, and makes at most one strong
CAS to increment readers. `try_write` makes one CAS from zero to the writer
bit. Successful acquisition uses acquire ordering. A changed value or failed
CAS returns `Busy`; there is no spin loop, fairness, lock upgrade, or blocking
wait. The caller decides what to do with unfinished work.

A successful `TryAccess` owns a guard until it is consumed or destroyed.
`take` transfers that guard. Guard borrows confine payload references; release
stores zero for a writer or atomically decrements readers, with release
ordering. Scope exit releases access during error unwinding; it does not undo
payload writes.

## Allocation and lifetime boundary

Unsafe view construction borrows existing storage; it neither allocates nor
transfers it. Device payload and state must already be device-accessible,
aligned, initialized, and retained until all work completes. Host and device
allocations are separate protection domains. Explicit move/destruction methods
keep borrowed views from passing ordinary resource/capture raw-byte checks,
including when nested in aggregates.

Structural lock bits preserve row addresses; resource leases preserve source
lifetimes; synchronization state coordinates concurrent data access. None of
those mechanisms substitutes for the others. Adapter capability declarations
also do not add synchronization automatically.

Implementation: {{< source "sync.mojo" >}}.
Evidence: {{< repo "test/synchronization_test.mojo" >}},
{{< repo "test/check_synchronization_contracts.py" >}},
{{< repo "test/gpu_synchronization_test.mojo" >}},
{{< repo "docs/design/research/apple-gpu-publication-ordering.md" "Apple publication research" >}}.
