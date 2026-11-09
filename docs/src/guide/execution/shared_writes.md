+++
type = "docs"
title = "Coordinate shared writes"
weight = 6
+++

Produce race-free shared results by writing per-particle output first and
reducing it after `run` completes. Start with [kernel access](../../systems_kernels)
and read the [execution restrictions](../../../reference/compatibility) before
changing targets. Standalone synchronization primitives exist; automatic
`KernelContext.sync` bindings and deferred retries do not.

## Write a separate output for each particle

The stage uses the same particle types and shared time.

{{< example file="particles/shared_outputs.mojo" region="model" >}}

A resource or mutable capture would be one shared value for every worker.
The additional `Displacement` below instead belongs to each entity.

Write all output fields before a later step reads them.

{{< example file="particles/shared_outputs.mojo" region="kernel" >}}

The filter grants read-write `Position`, read-only `Velocity`, and set-only
`Displacement`. Every visited row initializes its output. The same row-local
work can satisfy device/threaded restrictions without a shared increment.

Reduce the completed output on the coordinating host caller.

{{< example file="particles/shared_outputs.mojo" region="reduction" >}}

The query starts after synchronous kernel completion. One caller sums all 37
outputs, obtaining `(9.25, 18.5)`; there is no concurrent write to `total`.
For a fully parallel reduction, use disjoint partial-output components and
later passes with explicit dependencies. A single designated writer is also
valid when it need not read unfinished work from other threads, as in the
[capture count example](../captures#declare-explicit-slots-for-a-thin-kernel).
A thread-zero branch alone is not a global barrier.

## Use standalone host primitives when you own the storage

This independent check demonstrates atomic scalars and scoped guarded access
outside ECS kernels.

{{< example file="particles/shared_outputs.mojo" region="primitives" >}}

{{< api AtomicValue >}} owns a scalar; {{< api AtomicView >}} borrows it.
`fetch_add` returns the old value, and strong `compare_exchange` returns both
success and the observed value. Only `UInt32` and `Int32` scalars are supported;
add/subtract wrap at that width. Read views allow loads only.

{{< api Synchronized >}} owns guarded data; {{< api SyncView >}} borrows its
canonical protection state. Multiple read guards may coexist, while a writer
excludes all guards. `try_read`/`try_write` make at most one compare-exchange
attempt. Test {{< api TryAccess.is_acquired is_acquired >}} before consuming the
result with `take`. A false result means Busy, including a changed state or
reader saturation. It is not an automatic wait or a successful skipped update.

References from `guard.value()` stay within the guard's lifetime. Owners and
guards are noncopyable; copied views share protection identity. Release by
scope exit, including error unwinding, or by consuming `guard^.release()`.
Errors do not roll back payload writes. There is no fairness, blocking wait,
lock upgrade, or automatic retry: record required unfinished work for a later
pass, or skip only if the application permits losing that update.

## Match ordering and backend support

Public atomic operations default to relaxed ordering. Loads additionally accept
acquire, stores release, and updates acquire, release, or acquire-release.
Pass ordering at compile time. Relaxed counters do not publish adjacent ordinary
data. Guards use acquire/release internally.

| Target | Available behavior |
| --- | --- |
| CPU, NVIDIA, AMD | Full initial scalar/guard operation set, with CPU-wide or whole-device scope. Backend compilation does not establish hardware correctness. |
| Apple device | Relaxed/acquire loads, relaxed/release stores, relaxed add/subtract. Strong CAS, ordered add/subtract, and guards are explicitly rejected. |

Device primitives need aligned, initialized device-accessible payload/state that
stays alive until completion. Low-level unsafe view constructors do not allocate,
transfer, or validate that memory. A canonical unlocked state must protect every
overlapping guarded payload. Host/device allocations are separate domains;
these primitives do not permit concurrent CPU/GPU access to one allocation.

Do not put an `AtomicView` or `SyncView` into an ordinary resource/capture and
expect pointer transfer or automatic synchronization binding. Those raw-byte
paths reject these views and aggregates containing them. Kernel binding adapters
for these standalone owners remain unimplemented. A custom mutable resource
adapter may implement a supported atomic protocol over its own target-local
buffers; the [checked scatter example](https://github.com/larecs/larecs/blob/main/examples/scatter_resource.mojo)
demonstrates that separate contract.

## Run and troubleshoot

The driver creates 37 movers, checks the reduction, and checks the standalone
host operations.

{{< example file="particles/shared_outputs.mojo" region="check" >}}

From the repository root, run
`pixi run mojo run -I src examples/particles/shared_outputs.mojo`. Its PASS
covers host reduction and primitives, not GPU synchronization. Use per-row or
multi-pass output if a target lacks the operation you need; do not spin on Busy
or invent a `context.sync` binding. Structural locks and resource leases protect
invocation lifetimes and do not make shared writes race-free.

{{< example file="particles/shared_outputs.mojo" full=true >}}

[Synchronization internals](../../../inside/architecture/synchronization) explains
atomic scope, guard state, and why standalone views need target-local storage.
