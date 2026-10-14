---
id: "0018"
title: "Portable resource adapters"
status: proposed
status_notes: |
  Representation validated by a manual host/Apple GPU/host probe on Mojo 1.0.0.
  Optional-trait dispatch and associated-type lookup validated by a CPU probe.
  Resource access declarations, automatic registration in Larecs, getter
  resolution, device caches, and invocation failure handling are not implemented.
  The independent ECS-08 validator bug remains open. Does not replace decision 0002.
---

# Decision 0018: Portable resource adapters

## Context

Tree-D needs a leaf-distribution grid available to the same `KernelContext`
kernel on host and device. Its scientific container owns host data; the kernel
needs samples and metadata. Tree-D source is not present here, so its exact
sample type, layout, indexing, and validation remain integration questions.

Current host resource binding points into `ResourceStorage`. Device execution
creates invocation-local `DeviceResourceStorage`, transfers each resource's raw
bytes in both directions, and synchronizes on successful return. Ordinary and
selected device execution have separate transfer loops. `Resources[T]()` does
not declare access modes and `ResourceAccessor.get[T]()` is always mutable.

Trivial movability is not deep-transfer safety: the locked compiler accepts the
List-owning source in the [descriptor probe](../research/resource-view-probe.mojo).
This violates accepted ECS-08 and is tracked as an independent **Next release**
bug in the [roadmap](../../roadmap.md#repair-ecs-08-resource-transfer-validation).
Adopting an adapter design is not a prerequisite for repairing that validator.

## Decision

Propose an initial **read-only contiguous-buffer** adapter path:

| Role | Responsibility |
| --- | --- |
| Source | Owns authoritative host data and all current scientific configuration. |
| View | Trivial descriptor with target-local immutable sample pointers and metadata. |
| Adapter type | Stateless operations validating the current source and preparing invocation bindings. |
| Device cache | Per-world, context-local buffers keyed by source type; retains allocation capacity only. |

There is no adapter factory, captured instance configuration, mutable adapter
instance, per-world adapter override, or construction-input cache in this first
increment. Third-party sources use resource wrappers. Shared immutable plans,
explicit overrides, residency/revisions, collection serialization, writable
views, and asynchronous public execution are deferred.

### Resource capability and application API

Keep `ResourceType` as the host-storage contract. An optional
`DevicePassableResource` capability declares associated compile-time types:

| Member | Contract |
| --- | --- |
| `KernelView` | The same kernel descriptor type on host and device. |
| `Adapter` | Stateless adapter operations for this source and its `KernelView`. |

The adapter is selected by datatype; no adapter instance is constructed. Every
operation receives the current source explicitly. All configuration is read
from it during validation/preparation. No operation retains a source address
or configuration across invocations. Associated types establish the available
operations, not the safety of arbitrary application pointer code.

The following is proposed syntax, not a compiled Larecs API:

```text
LeafDistribution implements ResourceType, DevicePassableResource:
    comptime KernelView = LeafDistributionView
    comptime Adapter = LeafDistributionAdapter

world.resources.add(LeafDistribution(...))
# Registers type-only binding metadata; no GPU work.

required_resources = Resources().read[LeafDistribution]()

shade(context: KernelContext[filter, required_resources]):
    distribution = context.resources.get[LeafDistribution]()
    # Immutable LeafDistribution.KernelView on host and device.
    ... distribution.sample(x, y) ...

context.run[shade]()
context.run[shade, on_device=True]()
```

Bindings are keyed by the original source type, not by view type. There is one
resource and binding per source type in a world. Different sources may share a
view type. Views are invocation values and never enter the public resource table.
Wrappers around third-party scientific types declare the associated view and
adapter without modifying those third-party definitions.

### Access vocabulary and shared writes

Resource access modes have the same meaning as the component `Filter` modes:

| Declaration | Kernel access | Ordinary-resource device transfer in the initial increment |
| --- | --- | --- |
| `Resources().read[T]()` | Immutable `get[T]()` | Upload; no download. |
| `Resources().write[T]()` | `set[T](value)` only; `get[T]()` is rejected | Rejected until write-only shared-resource semantics are designed. |
| `Resources().read_write[T]()` | Mutable `get[T]()` | Upload and download through the existing bytewise path. |

`Resources[T]()` is equivalent to `read_write[T]`. `write` never authorizes
reading the old value; host write-only access uses the same set-only contract.

A resource is one shared value, not a separate component row per GPU thread.
Skipping upload for `write` and downloading afterward could publish uninitialized
bytes if no thread writes the resource. Multiple writers can also race. Therefore
new device `write` declarations are rejected before preparation, including empty
entity matches. Revisit them with decision 0016's protected access integration
and an explicit complete-initialization/publication contract. Guards alone do
not guarantee that a write actually occurs.

Existing ordinary-resource `read_write` device execution is unchanged: uploading
the prior value avoids the uninitialized-buffer issue, but applications remain
responsible for race-free writes. Access declarations do not add synchronization.

### Kernel access resolution

Declarations and getters name the **original resource type**:

| Resource and declaration | Kernel-facing type/support |
| --- | --- |
| `DevicePassableResource`, `read[T]` | Immutable reference to `T.KernelView` on both targets. |
| `DevicePassableResource`, `write[T]`, `read_write[T]`, or `Resources[T]()` | Compile error on both targets; reserved for future writable views. |
| Ordinary resource, `read[T]` | Immutable reference to `T`; device execution skips download. |
| Ordinary resource, `read_write[T]` or `Resources[T]()` | Existing mutable reference to `T` and existing transfer behavior. |
| Ordinary resource, `write[T]` | Host set-only access; device execution rejected initially. |
| `world.resources.get[T]()` | Original authoritative host `T`, with storage-access mutability. |

Adapted resources are reachable in kernels only through their views. No access
mode falls back to the owning source, so changing access modes cannot change an
adapted getter's kernel-facing type. Backend selection also cannot change it.
Host code edits the owning source outside kernels through `ResourceStorage`.

`get[T]()` checks membership against the original declared `T`. A distinct
associated view type is not implicitly declared. For an adapted read, its slot
points to invocation-owned `T.KernelView`; getter casts, descriptor sizing, device
validation, and transfers use that resolved type, never the owning source.
The source itself need not be trivially movable. Descriptor references and
pointees are immutable; a descriptor containing an exposed mutable pointer is
not a read-only view. Unsafe casts retain the ordinary unsafe contract.

Reject duplicate source declarations in any combination of modes. Binding
lookup, leases, and conflicts use source identity, not view identity. Cross-world
shared sources, arbitrary capture aliases, and externally retained raw pointers
are outside the initial guarantees.

For ordinary resources, eligibility behavior remains unchanged until its policy
is decided; the independently required ECS-08 safety repair is not deferred by
that policy discussion. This proposal introduces no automatic no-op device
adapter or new eligibility claim for plain values.

### Registration feasibility gate

Before relying on automatic registration, validate the locked compiler's ability
to detect optional trait conformance under a broad `ResourceType` bound, resolve
associated types, and select typed adapter operations in the variadic registration
path. Cover `add`, `set[add_if_not_found=True]`, copied type-only registration
metadata, and the resulting getter/transfer specializations.

The [CPU dispatch probe](../research/resource-trait-dispatch-probe.mojo) validates
`conforms_to` plus a guarded `comptime assert`, associated view/adapter types,
stateless adapter calls, the variadic consume pattern, insert-on-set, and copied
metadata around real `ResourceStorage`. It does not implement automatic Larecs
registration, getter resolution, actual world-copy cache reset, or GPU dispatch.
The full integration gate remains open. If it fails, automatic registration must
be replaced by an explicit, statically typed registration API and this proposal's
application API revised before acceptance.

Registration records only a checked source/view/adapter type association, not a
source pointer or scientific configuration. Add and insert-on-set must publish
source and metadata consistently; removal removes the binding and idle cache.
Runtime preflight still checks source presence and the correct device context,
even for a statically valid kernel and empty matches.

### Invocation preparation and cache ownership

The only persistent device state is a per-world cache keyed by source type and
owned with that world's device context. It holds reusable sample/descriptor
allocations, not authoritative data or source-derived configuration. World copies
copy sources and type-only metadata but start with empty device caches; moves may
transfer idle caches together with their sources and context.

**Edits and replacement use the same rule.** `set[T](...)`, changes to fields,
and `world.resources.get[T]() = T(...)` all become visible because each invocation
validates and prepares from the current stored source. No replacement detector,
factory snapshot, revision number, or explicit rebind is needed. Retained capacity
may be reused for any compatible current source; removing it releases idle cache
storage. Capacity reuse does not mean reuse of scientific contents.

Conceptually, the stateless adapter provides:

```text
validate(source, access) -> checked metadata
bind_host(source, checked metadata) -> invocation binding
prepare_device(source, context, cache, checked metadata) -> invocation binding
complete(binding, outcome) -> release after completion is established
```

Validate every requested resource and conflict before enqueueing any work. This
includes checked dimension/element/byte arithmetic, sample count, scientific
metadata, and explicit empty-grid/out-of-domain sampling semantics. Empty entity
matches still validate but allocate/upload nothing and launch no kernel.

Host preparation borrows current host samples and constructs the portable view.
Device preparation reuses sufficient capacity or grows the sample buffer, uploads
all current samples, constructs a descriptor with the device address, and uploads
that descriptor. Copy exactly the current logical sample count, not unused cache
capacity. Neither samples nor descriptors are downloaded for adapted reads.
Preparation reads configuration anew on every invocation; it never compares source
addresses to infer that configuration is unchanged.

An invocation binding retains source leases, descriptor storage, upload staging,
and device allocation leases. Owners remain live until all queued uses complete.
The ordinary/selected host/device paths share preparation and completion rules.

### Lifetime and failures

Keep synchronous `run`: successful return means all queued work is complete and
component/capture outputs are available. No public futures or background uploads.

While a source lease is active, reject source replacement/removal, binding changes,
cache replacement, copying the world, and nested execution reusing that binding.
Host execution also needs protection against reentrant mutation. Resource access
still uses untracked origins; existing references/raw pointers must not mutate,
resize, or escape across the invocation boundary. A runtime lease cannot repair
already-escaped aliases. This preserves the current `ResourceStorage.get`
`UnsafeAnyOrigin` contract without inventing a compiler-enforced borrow guarantee.

After an enqueue error, keep every owner alive while draining the same stream.
Propagate the original error with cleanup failures as additional context. If
completion cannot be confirmed, make the world unusable for further execution
and preserve owners until safe retention/destruction is established. A second
synchronization failure does not prove a drained queue. Validate that path against
the locked runtime before implementation; destructors swallowing errors are not
proof of safe cleanup. Earlier component/capture/host effects may remain visible;
no whole-run rollback is promised.

### Deferred scope

Writable adapted resources need mutable-view capabilities, source-based conflict
checks, concurrency guards, and validated staging before publication. Specify
publication granularity and decode failures before exposing them. Eventual
write-only device resources additionally need a complete-initialization contract.
Neither a write declaration nor a guard alone makes conditional initialization
safe. Residency, shared plans, adapter overrides, arbitrary collections, and
performance benefits remain unimplemented and unmeasured.

## Rationale

The descriptor probe demonstrates one kernel and one view type on host, actual
Apple GPU, and host again. Keeping adapters stateless and uploading every run
makes source edits and whole-instance assignment equally correct without trying
to observe mutations through existing mutable references. One buffer cache avoids
repeated allocation while keeping scientific ownership on the host.

Source-declared types make `get[Source]()` resolve statically. Read declarations
are the cheapest standalone increment: they eliminate unnecessary ordinary-resource
downloads before introducing adapter caches. Rejecting new shared device `write`
semantics avoids undefined initialization and concurrency behavior.

## Consequences

- Host storage remains authoritative; adapted kernel access uses only views.
- The initial path has stateless adapter operations, one context-local buffer cache,
  and invocation leases. Factory configuration and overrides are deferred.
- Ordinary resources retain their transfer path while ECS-08's existing validator
  bug is tracked independently. No claim of current safety compliance is made.
- Correctness depends on compiler integration and failure-path validation beyond
  the descriptor and trait probes; this record remains **Proposed**.

## Evidence

- [Descriptor probe](../research/resource-view-probe.mojo), run on Apple M4 with
  Mojo `1.0.0 (ed45d567)`, without `-g`, ASAN, or tracing. Four Int32 samples and
  37 rows yielded component values 10/19/28 on host/GPU/host with unchanged samples.
  A temporary mutation-through-immutable-pointer variant was rejected. This uses
  today's manually registered view getter, not the proposed source-oriented API.
- [CPU trait dispatch probe](../research/resource-trait-dispatch-probe.mojo), run
  with the same compiler. It requires no accelerator and covers the isolated
  registration/type-dispatch mechanisms listed in the feasibility gate.
- [Resource storage and validator](../../../src/larecs/resource.mojo),
  [accessor and execution paths](../../../src/larecs/system.mojo),
  [device transfers](../../../src/larecs/device_storage.mojo), and
  [world ownership](../../../src/larecs/world.mojo).
- [Upstream generic conformance checks](https://docs.modular.com/mojo/manual/generics/)
  describe guarded trait dispatch; local compiler evidence determines feasibility.
- [GPU queue and synchronization contract](https://docs.modular.com/mojo/manual/gpu/fundamentals/)
  explains why owners must survive queued uses.
- Existing resource and host/device execution regressions cover current APIs,
  not the proposed registration, access, cache, or failure contracts.
- [ECS-08 and ECS-10](../requirements.md), [decision 0002](0002-gpu-system-execution.md),
  [decision 0016](0016-kernel-memory-synchronization.md), and
  [ordered implementation gates](../../roadmap.md#support-heap-backed-device-resources).
