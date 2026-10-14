---
id: "0018"
title: "Portable resource adapters"
status: proposed
status_notes: |
  Representation validated with a manual host/Apple GPU/host probe on Mojo
  1.0.0. Source-oriented getter resolution, registration, access enforcement,
  invocation leases, cache isolation, and failure handling are not implemented.
  Does not replace decision 0002.
---

# Decision 0018: Portable resource adapters

## Context

The Tree-D use case needs a leaf-distribution grid available to the same
`KernelContext` kernel on host and device. The host owns scientific data;
the kernel needs samples and metadata rather than the owning container.
Tree-D source is not present in this repository, so its exact sample type,
layout, indexing, and validation remain application integration questions.

Larecs already represents kernel resources as pointers on both targets.
`_bind_host_resources` points directly into `ResourceStorage`; device execution
creates a `DeviceResourceStorage` per invocation, uploads each resource's bytes,
and downloads every descriptor before synchronizing. Ordinary and selected
device execution have separate preparation/copy-back paths. The world already
retains its device context and component buffers, but not resource adapters.

These are material limits of the existing API:

- `Resources[T]()` declares availability, not read/write access.
  `ResourceAccessor.get[T]()` always returns an untracked mutable reference.
- `ResourceStorage.get` deliberately uses `UnsafeAnyOrigin`; its separately
  allocated ownership cannot currently be expressed by a storage-bound origin.
  A structural selection lock does not establish a resource borrow.
- `constrain_device_safe_resources` checks trivial movability, not pointer
  reachability or ownership. On the locked compiler it even accepts the
  List-owning `Samples` in the [probe](../research/resource-view-probe.mojo).
  Copying such a container's bytes does not relocate its sample allocation.
- Successful device runs synchronize before return. Preparation, launch,
  download, and synchronization can fail before that successful boundary;
  adding invocation-local pointer descriptors requires explicit cleanup rules.
- `World` and `ResourceStorage` are copyable. Copying a cached pointer descriptor
  or sharing a mutable device buffer between copies is not a valid substitute
  for copying authoritative data and rebuilding target-local state.

## Decision

Propose a resource binding with three separate roles:

| Role | Ownership and responsibility |
| --- | --- |
| Source | World-owned authoritative host data; may own heap allocations. |
| View | Trivial kernel descriptor with target-local immutable sample pointers and metadata. |
| Adapter | Validates source data, prepares views, and owns reusable device allocations. |

The initial implementation should support **read-only contiguous scalar
buffers and trivial descriptors**. Kernels use exactly the same view type and
operations on both targets. Writable adapters, automatic residency tracking,
asynchronous public execution, collection serialization, and synchronization
sidecars remain separate extensions.

### Resource-declared device capability

Keep `ResourceType` as the baseline host-storage contract. Adding a host-only
resource must not require a view, adapter, GPU allocation, or device context.
Introduce an optional **`DevicePassableResource`** capability for sources that
provide a custom portable binding. Prefer this name to `GPUResource` (hardware
specific), `HostResource` (does not describe the additional capability), or
`DeviceResource` (could mean that the authoritative data lives on the device).
The existing `DeviceResourceType` alias denotes trivial register passability;
do not reuse it for the new ownership/transfer contract.

The source declares two associated compile-time types:

| Member | Contract |
| --- | --- |
| `KernelView` | The same kernel-facing descriptor type on host and device. |
| `Adapter` | A resource adapter whose source type is this resource and whose view type is `KernelView`. |

The adapter implements validation, host binding, device preparation, and
completion under the ownership rules below. Check the associated source/view
type relationship when registering the binding. Trait conformance establishes
that these operations exist, not that arbitrary pointer-bearing user code is
automatically safe; adapter authors remain responsible for their implementation.

Require an instance `create_adapter(self) -> Adapter` factory supplied by the
resource.
The trait provides no factory implementation and does not require `Adapter()`
to exist. The factory borrows the resource immutably and copies the configuration
needed by this instance's adapter; per-world overrides can be supplied explicitly
at registration. Its result must not retain a source borrow or allocate device
storage. Source-dependent dimensions and sample addresses are derived anew
during preparation, not captured by a one-time factory.

Declare the adapter **type per datatype**, but create and own mutable adapter
**state per resource binding in a world**. Two worlds containing the same
resource type have independent mutable state and device caches. Immutable
configuration may be shared under the optional caching contract below. Do not
share mutable adapter state globally by datatype or construct a fresh adapter
for every invocation. A binding retains its adapter across invocations while
borrowing the current source only for preparation and execution.
Exact Mojo associated-type/factory syntax still needs compiler evidence;
the examples here specify behavior rather than assert a compiled trait API.

Do not require `source.to_view()` and `source.to_adapter()` as the binding API.
A bare `to_view()` has no target, cache, or lease and cannot describe both host
borrowing and device allocation ownership. Passing those objects into the
source would merge the scientific container with backend preparation. Associated
types and the explicit factory keep the association discoverable while leaving
the adapter responsible for constructing invocation bindings.

There is no successful no-op device adapter. The default for an ordinary
host-only resource is **direct host borrowing with no device capability**.
This default needs no methods on the source. An explicit device request must
report unsupported resources rather than skip their preparation, manufacture
an empty view, or copy host pointers. A separately audited bytewise adapter can
serve supported plain values; its eligibility is independent of merely satisfying
`ResourceType` or trivial movability. Neither a factory nor a marker
trait turns arbitrary owning containers into bytewise-safe resources.

### Application API

The following is proposed syntax, not compilable public API:

```text
LeafDistribution implements ResourceType, DevicePassableResource:
    comptime KernelView = LeafDistributionView
    comptime Adapter = LeafDistributionAdapter

    create_adapter(self) -> Adapter:
        return LeafDistributionAdapter(configuration=self.adapter_configuration)

world.resources.add(LeafDistribution(...))
# add registers the source-declared binding; no GPU work occurs here.

required_resources = Resources().read[LeafDistribution]()

shade(context: KernelContext[filter, required_resources]):
    distribution = context.resources.get[LeafDistribution]()
    # distribution is an immutable LeafDistribution.KernelView on both targets.
    ... distribution.sample(x, y) ...

context.run[shade]()                 # host
context.run[shade, on_device=True]()  # device; same kernel
```

Applications add the source once, mutate the authoritative source between runs,
and select the execution target at `run`. They do not construct target pointers,
upload descriptors, or request synchronization themselves. Views are invocation
values, not additional authoritative resources stored in the public resource
table. `ResourceStorage.get[LeafDistribution]()` remains the host editing API.

For a conforming source, adding it automatically registers its source-keyed
binding and calls the instance factory to create binding-owned adapter state
without creating a device cache. Removing the source removes its binding after
leases have ended. Replacing a source instance retains its type association but calls
the replacement's factory, replaces adapter state, and discards the old prepared
views and device cache. Validate the replacement and create its new adapter
before publishing either; failure leaves the existing source and binding intact.

Ordinary sample edits or sample-buffer growth keep the adapter and reuse adequate
device capacity; preparation reads the current dimensions, samples, and metadata.
Changes to configuration captured by the factory require explicit rebinding or
source replacement before the next run. An explicitly supplied adapter override
is tied to the source instance: replacement invalidates that explicit binding
and requires a new explicit bind, rather than silently reusing stale configuration
or switching to the resource's factory. Validate binding collisions before
committing an add so failed registration cannot leave an inserted source with
a missing binding.

Retain an explicit source-keyed binding operation for per-world adapter
configuration. A supplied adapter must match `Source.Adapter` and
`Source.KernelView`; it cannot select a different getter return type at runtime.
Do not silently overwrite an automatically registered binding: require an
explicit replacement operation, available only with no active lease. Third-party
types that need a different portable representation require a resource wrapper
implementing `DevicePassableResource`; its factory may delegate to application
adapter code. Arbitrary source/view pairs would need a separate compile-time
binding declaration and are outside this initial API.

Registration establishes a checked source-type/view-type/adapter-type triple
keyed by source type. Use one binding per source; reject duplicate registration
and validate that the source exists. Store source identity, not a permanent
source pointer: replacing the source between invocations must be observed by
the next preparation. Different source types may use the same view type because
the kernel selects a binding by source, not by view. An ordinary stored resource
whose type happens to equal a view type does not collide with an associated
view, which is never inserted into the public resource table.

### Kernel access resolution

Kernel declarations and getters name the **original resource type**. Resolve the
representation at compile time from that type's capability and declared access:

| Access site/declaration | Getter result | Execution support |
| --- | --- | --- |
| Kernel `read[T]`, with `T: DevicePassableResource` | Immutable reference to `T.KernelView` | Same descriptor type and API on host and device; the adapter supplies target-local storage. |
| Kernel `read[T]`, ordinary resource | Immutable reference to `T` | Direct host borrowing; device use requires an audited bytewise representation. |
| Kernel mutable declaration of a `DevicePassableResource` | Mutable reference to the original `T` on host | Device execution rejects this mode in the initial read-only adapter implementation. |
| Kernel mutable declaration of an ordinary resource | Mutable reference to `T` | Existing host behavior; device use requires supported bytewise transfer. |
| `world.resources.get[T]()` | Reference to the original authoritative host `T`, with storage-access mutability | Host editing API, outside the kernel adapter mapping. |

The getter's return type is a function of the compile-time resource declaration,
not the selected backend or the state of a runtime registry. For a read-only
adapted resource, host execution must also bind `T.KernelView`, even if directly
borrowing `T` would be possible there. This preserves one kernel implementation.
`get[T]()` checks membership against the original declared `T`. When its
associated view is a distinct type, `read[T]` does not also authorize
`get[T.KernelView]()`. An adapted read exposes the view rather than the owning
source allocation.

Keep original source identity separate from prepared representation internally.
Each accessor slot for an adapted read points to its invocation-owned view;
`get[T]()` casts that slot to the resolved view type, never to the owning `T`.
Device validation, descriptor sizes, and transfers use the resolved kernel type
`T.KernelView`, so the source itself need not be trivially movable or GPU-safe.
Resolve source existence, adapter configuration, leases, and access conflicts
using the original source type. Never upload the owning source merely because it
appears in the kernel's resource declaration.

There are two distinct checks. Source types, associated representations, and
declared access modes are known at compile time. Check adapter/view conformance
when registering a concrete source and reject unsupported representation or
access modes when specializing device execution. Before execution, also validate
the **actual world binding** for every requested source: the binding and source
instance exist, the adapter configuration is valid, and its cache belongs to the
correct context. This applies even to empty entity matches and occurs before any
queued work. Dynamic resource insertion/removal and context availability still
require descriptive runtime preflight errors naming the resource; a statically
valid kernel does not prove that its world is populated correctly. Checking for
method names at launch is not the capability mechanism.

Kernel declarations must distinguish access at compile time. `get[Source]()` for
an adapted read declaration exposes an immutable descriptor. Its sample operations
must also expose immutable pointees; immutable access to a descriptor containing
a mutable pointer is insufficient. View implementers must not provide a safe
mutation escape hatch. Unsafe pointer casts retain the usual unsafe contract.

Preserve existing `Resources[T]()` as a legacy read/write declaration; it does
not implicitly request a read-only view. Read-only adaptation is selected only
by an explicit `read[T]` declaration. Preserve direct mutable host access for
that legacy mode, including adapted source types, but reject device write or
read_write requests for adapted sources before any transfer or launch. Do not
fall back to raw-byte source transfer for unsupported mutable adapter modes.
Resolve access by **source identity**, not view type: read-only and mutable
declarations for the same source conflict and cannot produce an ambiguous
getter result. Reject duplicate declarations rather than silently creating two
independently mutable replicas. Future writable views need an explicit access
and migration design before changing this return-type table.

The initial binding operates within one world and synchronous invocation.
Cross-world shared sources, arbitrary aliases through captures, and externally
retained raw pointers are outside its guarantees; type identity cannot prove
their independence. Document this explicitly instead of claiming universal
alias detection or thread safety.

### Preparation and storage ownership

Separate binding-owned adapter configuration/state from target-local cache state.
Each world's device context owns the latter, keyed by that resource binding's
identity. It must not be reused on another context, including after a world copy.
Copy authoritative data and rebuild source-declared adapters from the copied
resource instances; this may occur lazily before their first invocation so
fallible preparation does not become part of the world's copy constructor.
Rebuild explicit bindings from owned configuration. Mutable adapter state is
independent; immutable configuration may be reused under the optional caching
contract below. Device caches start empty, and views are reconstructed.
Moving an idle world may transfer its adapters and caches with the associated
sources and context.

Conceptually provide:

```text
validate(source, access) -> checked metadata
bind_host(source, checked metadata) -> invocation binding
prepare_device(source, context, cache, checked metadata) -> invocation binding
complete(binding, outcome) -> release after completion is established
```

The adapter's source access is immutable in this first implementation. An
invocation binding retains the source lease, descriptor storage, allocation
leases, and any upload staging. Neither a returned view nor its pointers own
these objects. Never store a prepared view into the authoritative source table.

The Tree-D adapter validates dimensions, checked element-count/byte-count
arithmetic, sample count, and required scientific metadata before enqueueing
work. Define the application's empty-grid and out-of-domain sampling behavior;
do not infer it from a dangling pointer or permit division/indexing by zero.
Borrow the contiguous host allocation for host execution. For device execution:

1. Reuse sufficient capacity, or allocate a larger sample buffer after the
   previous invocation has completed. Empty buffers require a defined sentinel
   representation and no zero-length dereference.
2. Upload all current samples on every preparation. Updating existing values,
   resizing the source, and replacing it must all be observed without revision
   tracking.
3. Construct the view using that allocation's **device address**, not the host
   address. Retain host descriptor storage until its upload finishes.
4. Upload the descriptor and bind its pointer in `ResourceAccessor`. No sample
   or descriptor download occurs for the read-only binding.

Validate all requested bindings and access conflicts before enqueueing any
work. Empty entity matches still validate declarations and source metadata,
but allocate/upload nothing and invoke no kernel. Use one preparation/completion
implementation for ordinary and selected execution, including host closures,
so empty ranges and errors obey the same contract.

### Optional reuse by construction inputs

A later opt-in cache may reuse immutable adapter configuration or preprocessing
plans when their construction inputs are equal. If an adapter instance consists
entirely of immutable configuration, that instance may itself be shared; all
mutable binding state and device allocations remain in separate owners. Generic
adapters with mutable state are not eligible for whole-instance memoization.

Require an explicit, owned key containing the adapter type and every input that
affects construction. Use value equality as well as hashing; a matching hash
alone is insufficient. Do not use resource type, source address, or mutable
references as a substitute for construction inputs. The factory must explicitly
opt into deterministic construction from that key; arbitrary `create_adapter(self)`
implementations may depend on ambient state and cannot be memoized automatically.
Device-dependent plans also require the correct context/backend identity and
belong in a context-owned cache, not a global configuration cache.

For example, two leaf distributions with identical sampling-policy configuration
can share an immutable sampling plan while retaining separate sample uploads,
views, source leases, and device buffers. A configuration-cache hit does not
establish equality of scientific samples, synchronize them, or change source
identity for alias checking. Sharing uploaded samples would require a separate
immutable-data snapshot and residency design and is outside this proposal.

Source replacement still recreates binding state and clears its device cache;
it may obtain equal immutable configuration from this cache. If construction
inputs change in place, the existing explicit-rebind rule still applies. Cache
entries must own their configuration, bindings must retain it while in use, and
eviction must not invalidate active bindings. Bound cache memory or make its
lifetime explicit. Measure construction cost before introducing cache-key and
retention overhead: the initial per-binding adapter is already reused across
invocations and does not require this optimization.

### Lifetime and completion

Preserve synchronous `run`: all queued reads of source/staging data and device
views complete before successful return and lease release. No public future,
background upload, or implicit persistent data residency is introduced.

While a lease is active, reject resource replacement/removal, binding changes,
cache replacement, world copying, and nested execution that would reuse the
same binding. Host execution also needs this protection against reentrant
mutation. Borrow conflicts must be detected before side effects. Existing
untracked references acquired earlier remain subject to the documented rule
that they cannot mutate, resize, or escape across execution boundaries.
Do not claim that a runtime lease repairs already-escaped raw pointers.

On an error after enqueueing, retain all owners while attempting to drain the
same device stream, then propagate the original error with any cleanup failure
as additional context. `complete` must not publish data after unsuccessful work.
A second synchronization failure does not prove the queue is drained:
establish the locked runtime's safe destruction/retention behavior before
implementing that path, and make the world unusable for further execution if
completion is unknown. A destructor that discards synchronization errors is
not adequate evidence of safe lifetime handling.

### Default resources and later writes

Do not infer default-adapter eligibility from trivial movability. Plain
pointer-free scalars and explicitly audited trivial values can retain direct
host borrowing and bytewise device transfer; owning or pointer-bearing values
need an explicit adapter or an explicit unsafe device-validity contract.
The probe demonstrates why the existing validator cannot certify this.
Finalizing the eligibility API and compatibility policy is an implementation
gate; this proposal does not silently tighten today's accepted public API.

Later writable adapters need separate mutable-view capabilities, source-based
conflict checks, explicit GPU concurrency rules, and validated staging before
publication. A `write` declaration does not make simultaneous GPU writes safe.
Specify whether publication is atomic per binding or across all bindings and
what happens when one adapter's decode fails. Resource staging alone cannot
promise whole-run rollback: component/capture writes and host kernel effects
may already be visible. Synchronization-backed views must follow decision 0016
and must not retain an unguarded path to protected storage.

## Rationale

The portable-view split is viable: the checked-in probe executes one
`KernelContext` kernel over one descriptor type on host, actual Apple GPU, and
host again, with identical expected component results. Manual relocation proves
the representation, while also exposing the current unconditional descriptor
copy-back and lack of adapter-owned lifecycle handling.

Keeping execution synchronous avoids introducing events and public lease
management merely to support a read-only grid. Uploading every time avoids
revision bugs and gives source replacement straightforward semantics. Explicit
bindings avoid requiring application scientific containers to be device types
or attempting to serialize arbitrary `Dict` ownership.

Resource-declared associated types remove repetitive registration from the
common application path. Making device adaptation optional preserves ordinary
host resources, while explicit capability checks avoid ambiguous no-op defaults.
Source-oriented declarations let kernels keep `get[Source]()` while receiving a
portable read-only view on either target. Associated types make that return type
statically known. Explicit adapter configuration and resource wrappers accommodate
third-party scientific types without requiring changes to their definitions.

The proposal is suitable as an architectural direction, but the successful
descriptor probe does **not** establish that an integrated adapter is safe.
Access enforcement, world copies, aliases, and drain failures need implementation
and negative-test evidence before adoption as an accepted requirement.

## Consequences

- End users gain one kernel and one view API; host ownership remains ordinary
  scientific application code. Adapter authors handle transfer details once.
- Read-only adapters avoid unnecessary downloads and reuse device allocation
  capacity. Neither a speedup nor Tree-D integration has been measured.
- Registration and preparation add work to the invocation boundary. Keep the
  no-adapter path cheap and measure both setup and complete execution.
- Resource mutation/copy rules and compile-time access declarations are new
  contracts. Preserve legacy behavior or document an intentional beta migration.
- Explicit read declarations of adapted resources return their associated view;
  mutable host declarations and host storage access still return the source.
  Changing a declaration's access mode may therefore change its static result
  type. Backend selection does not change it.
- `DevicePassableResource`, associated types, and automatic binding registration
  are proposed APIs, not implemented features. Host-only resources keep their
  existing storage contract; unsupported device requests need a clear diagnostic.
- This record remains Proposed. Accepted requirements and existing raw-byte
  execution semantics are unchanged. Implementation gates live in the roadmap.

## Evidence

- [Manual descriptor probe](../research/resource-view-probe.mojo), run on Apple
  M4 with Mojo `1.0.0 (ed45d567)`, using a normal build without `-g`, ASAN, or
  tracing. Four Int32 samples, 37 rows; host/GPU/host component values were
  10/19/28, and authoritative samples remained unchanged. No timing claim.
  A temporary variant assigning through `SamplesView.values` failed compilation
  with `expression must be mutable in assignment`; the existing mutable
  descriptor accessor itself remains unchanged.
  This probe uses the current manually registered view-type declaration/getter;
  it does not validate proposed `read[Source]` or automatic `get[Source]` resolution.
- [Resource storage and validator](../../../src/larecs/resource.mojo),
  [accessor and both execution paths](../../../src/larecs/system.mojo),
  [device uploads/downloads](../../../src/larecs/device_storage.mojo), and
  [world ownership](../../../src/larecs/world.mojo).
- [Upstream GPU lifetime and synchronization contract](https://docs.modular.com/mojo/manual/gpu/fundamentals/):
  operations are queued and owners must survive until their use completes.
- Existing regressions: `test/resource_test.mojo`,
  `test/gpu_resource_test.mojo`, `test/cpu_execution_test.mojo`, and
  `test/gpu_entity_selection_test.mojo`. They cover current APIs, not adapter
  access enforcement, leases, or failure recovery.
- [Requirements ECS-08 and ECS-10](../requirements.md),
  [decision 0002](0002-gpu-system-execution.md),
  [decision 0016](0016-kernel-memory-synchronization.md), and
  [implementation roadmap](../../roadmap.md).
