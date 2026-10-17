---
id: "0018"
title: "Portable resource adapters"
status: accepted
status_notes: |
  Implemented for read-only contiguous buffers and trivial descriptors.
  Automatic registration, source-oriented getters, source leases, cache reuse,
  and staged transfers are verified on Mojo 1.0.0 and Apple M4.
  Extends decision 0002. Decision 0022 extends the read-only access rules
  below with opt-in mutable views; `KernelView` is now an alias for
  `View[False]`.
---

# Decision 0018: Portable resource adapters

## Context

A scientific resource can own host allocations while a kernel needs only samples
and metadata. Copying its owning `List` or `Dict` as raw bytes cannot relocate
those allocations. Tree-D's leaf grid motivated this requirement; its source is
not present in Larecs, so application compatibility remains unverified.

The former resource validator checked trivial movability and accepted a
List-owning source. This violated ECS-08 independently of the adapter proposal.
Ordinary resources also lacked access modes and were always downloaded.

## Decision

Introduce the optional `DevicePassableResource` trait on the owning source type:

| Member | Contract |
| --- | --- |
| `KernelView` | Trivial descriptor with immutable sample pointers and plain metadata. |
| `Adapter` | Stateless `ResourceAdapter` type with matching `Source` and `View`. |

The adapter provides `validate(source)`, `bind_host(source)`, and
`prepare_device(source, cache)`. Each operation reads current source data and
configuration. There is no adapter instance, factory, default constructor,
captured configuration, explicit override, or construction-input cache.
Third-party types can be wrapped in an owning resource that declares the trait.

`ResourceStorage.add` and insert-on-`set` automatically check and register the
source/view/adapter association. Registration records source identity only; it
performs no GPU work. Removing a source removes its metadata and idle cache.

### Source-oriented kernel API

```mojo
comptime Samples = BufferResource[DType.float32]
comptime required = Resources().read[Samples]()

def sample(context: KernelContext[Filter().include[Float32](), required]):
    ref values = context.resources.get[Samples]()
    for entity in context:
        entity.get[Float32]() += values[0]
```

For adapted sources, `get[Source]()` always returns an immutable
`Source.KernelView`, on both targets. Kernels cannot obtain the owner, and views
never enter the public resource table. World-side `resources.get[Source]()`
continues to expose the owner for edits between invocations.

Bindings, cache keys, and conflicts use source type, not view type. Distinct
sources may share one view type. Duplicate declarations of a source are rejected.

| Declaration | Kernel API | Ordinary device transfer |
| --- | --- | --- |
| `Resources().read[T]()` | Immutable `get[T]()` | Upload; no download. |
| `Resources().write[T]()` | Host `set[T](value)` only | Rejected. |
| `Resources().read_write[T]()` | Mutable `get[T]()` or `set[T](value)` | Upload and staged download. |

`Resources[T]()` retains legacy `read_write` access. Adapted sources require
`read`; mutable and legacy declarations are rejected on both targets. Device
write-only declarations are rejected even for empty matches or host fallback.
A shared resource is one value, not one component row per thread: skipping
upload could publish uninitialized bytes when no thread writes. Existing plain
`read_write` kernels remain responsible for race-free shared writes.

Ordinary device resources now require a pointer-free representation whose
fields are recursively supported trivial values. Numeric SIMD/scalars, `Bool`,
and aggregates of those values are accepted; ownership, pointers, custom
copy/move/destruction, and opaque field representations are rejected. In this
increment, fixed `Array` fields are opaque to the validator and are rejected.
This is the required ECS-08 repair, not a blanket claim that any trivially
movable source is device-safe. Heap-backed host resources remain supported.

### Preparation and ownership

Each world retains a `ResourceDeviceCache` per source type, tied to its native
device-context handle. Nonnegative allocation slots belong to the adapter;
slot `-1` contains Larecs's view descriptor. Only capacity is reused: samples
are uploaded and descriptors rebuilt every invocation. `cache.upload` snapshots
pointer-free contiguous data into native owned staging before enqueueing a copy.

Source field edits, `set`, and whole-instance assignment through
`world.resources.get[T]() = T(...)` all follow the same rule: validate and prepare
from the current source. No revision, replacement detector, or rebind is needed.
World copies deep-copy host sources and type metadata but start with empty
resource caches. Idle moves transfer sources and caches with their contexts.

All source presence, access, adapter invariants, lease conflicts, and existing
cache contexts are validated before work is queued. Empty device matches still
validate but create no device resource allocation, upload, or launch. Scientific
adapters must validate dimensions, arithmetic, sample counts, and sampling
semantics in `validate`; Larecs cannot infer those invariants.

An invocation retains a tracked borrow of the resource table, exclusive
source-type leases, and host descriptor owners. Public lookup, replacement,
removal, and nested binding of a leased source raise. Copying or destroying
leased storage through an escaped alias aborts, including with assertions
disabled, because Mojo's lifecycle methods cannot raise. Moving a live tracked
owner is rejected by the compiler; the move constructor also checks leases.

Source references keep the existing `UnsafeAnyOrigin` contract. Previously
escaped references must not mutate or resize storage during execution. Runtime
leases cannot repair arbitrary raw aliases. Kernel references and views must
not escape the synchronous invocation.

`DevicePointer` borrows a host-side `DeviceBuffer` descriptor, so kernel arguments
borrow the persistent cached descriptor, never a temporary buffer handle.
Adapter authors must use cache-owned allocations and `cache.upload` for transfers;
returning pointers into temporary storage or enqueueing external host pointers
violates the adapter contract. Descriptor validation rejects mutable pointers;
pointer addresses and pointee interpretation remain the adapter's responsibility.

### Completion and failures

`run` is synchronous. High-level component, capture, and resource uploads
snapshot into native owned host buffers. Downloads land in native owned staging
and are published to host values only after successful synchronization. A failed
invocation discards its staged outputs; it does not promise whole-world rollback.

After an enqueue or completion failure, drain the same queue and preserve the
original error. If draining also fails, include both errors and reject future
execution on that world, including empty and resource-free calls. The world-level
health flag survives replacement of its public resource table. No queued copy
accesses caller-owned host memory. Native buffer release schedules destruction
after queued uses, retaining allocation lifetime even when completion cannot
be confirmed; source leases are released at the invocation boundary. Cleanup
does not rely on a destructor attempting synchronization and swallowing errors.

## Rationale

Stateless operations and unconditional uploads make editing and replacement
correct without intercepting mutable references. Source-declared associated
types preserve `get[Source]()` while giving kernels one portable representation.
Read-only views cover contiguous scientific grids without generic serialization
or writable-view publication semantics.

## Consequences

- Host owners remain authoritative; kernel views borrow target-local storage.
- Ordinary resources gain explicit permissions while legacy declarations retain
  mutable access. Unsafe ordinary device representations now fail compilation.
- Staging adds host allocation/copy costs to synchronous device execution; cache
  reuse does not imply residency or application speedup.
- Writable adapters, shared plans, overrides, revision tracking, arbitrary
  collections, and asynchronous public execution remain outside this increment.

## Evidence

- [Adapter integration tests](../../../test/resource_adapter_test.mojo) cover the
  identical host/device/host kernel, two sources sharing a view, current metadata,
  edits and replacement, growth/shrink/empty samples, cached allocation reuse,
  independent world copies, selected rows, empty-match validation, source leases,
  failure after upload and retry, and staged publication on Apple M4.
- [Host tests](../../../test/resource_adapter_host_test.mojo) check descriptors
  across multiple closure callbacks under AddressSanitizer.
- [Compiler/lifecycle contracts](../../../test/check_resource_contracts.py) reject
  incompatible access, mutable descriptors, owning raw transfers, duplicate
  sources, and moving borrowed storage; subprocesses verify lease aborts with
  assertions disabled. They run in the complete test suite.
- Unknown completion is tested using an injected completion-reporting failure
  after draining the real test queue. This verifies poisoning and diagnostics;
  it does not simulate physical device loss. Native ownership follows the
  [buffer release contract](https://github.com/modular/modular/blob/main/max/mojo/max/gpu/host/device_context.mojo).
- [Grid probe](../research/resource-view-probe.mojo) exercises the integrated
  source-oriented API. The earlier manual descriptor probe established only
  representation feasibility; [trait dispatch research](../research/resource-trait-dispatch-probe.mojo)
  established isolated compiler mechanisms. Full registration is now covered by
  actual `add`, insert-on-`set`, copying, and execution tests.
- [Ordinary resource benchmark](../../../benchmark/resource_execution_benchmark.mojo),
  [adapter benchmark](../../../benchmark/resource_adapter_benchmark.mojo), and
  [measurement boundaries](../../src/guide/benchmarks.md#resource-execution)
  separate unchanged ordinary calls from complete adapter invocations.
