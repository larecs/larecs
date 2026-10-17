---
id: "0022"
title: "Mutable adapted resource access"
status: accepted
status_notes: |
  Accepted; experimental. Implemented for sequential host, opted-in threaded
  host, and device execution. Host paths, including threaded execution, are
  tested on Linux x86-64. Device paths compile for NVIDIA sm_80 and AMD gfx942
  but have not run on a GPU; Apple targets were not compiled because the Metal
  toolchain was unavailable. Extends decisions 0018 and 0019.
---

# Decision 0022: Mutable adapted resource access

## Context

[Decision 0018](0018-portable-resource-adapters.md) admitted adapted resources
with `read` access only. Tree-D fills a shared leaf-distribution grid from tree
components: the kernel computes a density, reserves per-cell slots with atomic
counters, and writes each tree into its slot. Without writable adapters, the
grid writer travels through a `MutCapture` on the host and cannot use the
adapter's device transfers. A writer needs different operations from a reader,
fresh output must be initialized exactly once per invocation, and device results
must be published only after completion.

## Decision

### Views and capabilities

`ResourceAdapter.View` becomes an access-selected mapping:

```mojo
comptime View[mut: Bool]: TrivialRegisterPassable
```

`DevicePassableResource` forwards it, with defaults:

```mojo
comptime View[mut: Bool]: TrivialRegisterPassable = Self.Adapter.View[mut]
comptime KernelView: TrivialRegisterPassable = Self.View[False]
```

Read and writer views may be distinct types, for example
`comptime View[mutable: Bool] = FillView if mutable else ReadView`. `KernelView`
remains as a compatibility alias for `View[False]`. No separate mutable-resource
trait is introduced.

Two adapter capabilities default to `False`:

| Capability | Admits |
| --- | --- |
| `supports_mutation` | `write` and `read_write` declarations on sequential host execution. |
| `supports_concurrent_mutation` | The same declarations on device and threaded host execution. Requires `supports_mutation`. |

An adapter may declare concurrent mutation only when every mutable view
operation is safe under concurrent use, through atomics or provably disjoint
writes. Larecs's exclusive source lease does not prevent races among kernel
workers. Users and adapter authors are responsible for safe resource access.

### Access semantics

| Declaration | Kernel `get[T]()` | Preparation |
| --- | --- | --- |
| `Resources().read[T]()` | `T.View[False]` | `bind_host` / `prepare_device` |
| `Resources().write[T]()` | `T.View[True]` | Fresh, adapter-initialized output |
| `Resources().read_write[T]()` | `T.View[True]` | Existing contents preserved |

`Resources[T]()` keeps its legacy `read_write` meaning. Kernels receive an
immutable reference to the selected descriptor; writer views mutate shared
state through pointers into adapter-managed backing buffers. `set[T]` is
rejected for adapted sources. Ordinary resources keep their existing access
behavior, including rejected device write-only declarations.

Mutable preparation receives the full `ResourceAccess` mode, because a
mutability Boolean cannot distinguish `write` initialization from `read_write`
preservation:

| Hook | Called |
| --- | --- |
| `bind_host_mutable[access](mut source)` | Once per host invocation before any kernel, including threaded and empty runs, and for empty device runs. |
| `prepare_device_mutable[access](mut source, mut cache)` | Once per device invocation with matching rows. |
| `stage_device_results[access](mut source, mut cache)` | After the kernel is queued; stages downloads with `cache.download`. |
| `finalize[access](mut source)` | Once per successful invocation, after execution and publication. |

The hooks have defaults that raise, except `finalize`, which does nothing.
Capability checks reject unsupported access at compile time, so the raising
defaults are unreachable through public execution. `ResourceDeviceCache` adds
`upload_mutable`, `fill`, and `download` for mutable buffers.

### Lifecycle

The existing invocation, cache, lease, and transfer-frame machinery runs these
steps:

1. Validate declarations, capabilities, and source invariants (`validate`).
2. Acquire the source lease and prepare invocation-owned views and buffers.
3. Execute every matching row, archetype, and host chunk against the same
   backing storage. Output is never reset per archetype, chunk, or worker.
4. Device runs stage outputs, synchronize the world's queue, and publish.
   Then `finalize` runs, and the lease is released.

Runs without matching rows still prepare and finalize. An empty device run
prepares through `bind_host_mutable` and queues no device work, as for a host
run without matches.

Device preparation uses the world's existing queue and the source-keyed cache.
Allocations, descriptors, and staging stay alive until completion is confirmed.
Mutable adapted sources are prepared on every run; device copy reuse
([decision 0021](0021-skip-unchanged-device-uploads.md)) never skips them.
Mutable runs advance the source revision.

### Failure and publication

- Validation and capability failures happen before any preparation.
- Host kernels write backing storage directly. If a later preparation step
  fails, partial or initialized host output remains, and `finalize` does not
  run. There is no rollback.
- Device outputs are staged and published only after synchronization succeeds.
  An enqueue or completion failure discards staged outputs and uses the
  existing drain and poisoned-world handling.
- A raising `finalize` reports an error after outputs were published. Outputs
  and revisions stay as published; the world remains usable.
- Leases are released on every path.

## Rationale

An associated-type mapping keeps one trait pair and the source-oriented
`get[Source]()` API. Distinct writer types let adapters expose only safe
operations, such as atomic slot reservation, without mutable descriptors.
Explicit capabilities keep existing read-only adapters valid and make
concurrent mutation an informed opt-in rather than an implied guarantee.
Preparing once per invocation and finalizing after publication give one
coherent output across ranges, chunks, and device launches. Staged device
publication reuses decision 0018's ownership rules instead of adding rollback.

Separate mutable traits, a Boolean mutability parameter for preparation, and
per-archetype preparation were rejected for the reasons above.

## Consequences

- Breaking: external adapters must declare `comptime View[mut: Bool] = ...`,
  return `Self.View[False]` from read hooks, and drop explicit `KernelView`
  declarations. Errors for mutable declarations of read-only adapters now say
  mutation support is required.
- Mutable sources cost a preparation, upload or fill, and download on every
  device run. Results must fit preallocated device buffers; host targets must be
  sized before staging.
- Atomic maximum and other compare-exchange reductions are unavailable on Apple
  GPUs in Mojo 1.0 (decision 0016); portable reductions use `fetch_add`.
- Ordinary mutable resources remain unsupported by threaded execution.

## Evidence

- [Host tests](../../../test/mutable_resource_adapter_host_test.mojo) cover view
  selection, fresh `write` versus preserving `read_write`, read views, colliding
  writers, shared totals, overflow reporting and propagation, empty queries,
  multiple archetypes, repeated runs, threaded execution at one and four
  workers, capturing kernels, selections, a sequential-only adapter, and lease
  and revision cleanup. The [synthetic scatter fixture](../../../test/fixtures/scatter.mojo)
  makes no assumption about slot order.
- [Device tests](../../../test/mutable_resource_adapter_test.mojo) cover the same
  contract with device copy reuse, empty matches, overflow, and selections. They
  compile with `--target-accelerator=sm_80` and `gfx942`. They skip at runtime
  without a GPU, and have not yet run on one.
- [Resource](../../../test/check_resource_contracts.py) and
  [threaded](../../../test/check_threaded_contracts.py) contract checks reject
  unsupported mutable access, sequential-only adapters on device or threaded
  execution, `set` on adapted sources, descriptor mutation, and inconsistent
  capabilities.
- [Scatter example](../../../examples/scatter_resource.mojo) demonstrates
  capture-free execution on every target.
