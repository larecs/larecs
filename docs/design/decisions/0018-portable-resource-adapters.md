---
id: "0018"
title: "Portable resource adapters"
status: proposed
status_notes: |
  Representation validated with a manual host/Apple GPU/host probe on Mojo
  1.0.0. Registration, access enforcement, invocation leases, cache isolation,
  and failure handling are not implemented. Does not replace decision 0002.
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

### Application API

The following is proposed syntax, not compilable public API:

```text
world.resources.add(LeafDistribution(...))
world.bind_resource[LeafDistribution, LeafDistributionView](
    LeafDistributionAdapter(...)
)

required_resources = Resources().read[LeafDistributionView]()

shade(context: KernelContext[filter, required_resources]):
    distribution = context.resources.get[LeafDistributionView]()
    ... distribution.sample(x, y) ...

context.run[shade]()                 # host
context.run[shade, on_device=True]()  # device; same kernel
```

Applications register once, mutate the authoritative source between runs,
and select the execution target at `run`. They do not construct target pointers,
upload descriptors, or request synchronization themselves. Views are invocation
values, not additional authoritative resources stored in the public resource
table. `ResourceStorage.get[LeafDistribution]()` remains the host editing API.

Registration establishes a checked source-type/view-type/adapter-type triple.
Use one binding per view type; reject duplicate registration and collisions
with an ordinary stored resource of that view type. Validate that the source
exists. Store source identity, not a permanent source pointer: replacing the
source between invocations must be observed by the next preparation.
Multiple read-only views of one source may be supported if leases are shared.
Initially rejecting such registrations is acceptable if documented explicitly.

Kernel declarations must distinguish access at compile time. `get[View]()` for
a read declaration exposes an immutable descriptor. Its sample operations
must also expose immutable pointees; immutable access to a descriptor containing
a mutable pointer is insufficient. View implementers must not provide a safe
mutation escape hatch. Unsafe pointer casts retain the usual unsafe contract.

Preserve existing `Resources[T]()` behavior for ordinary resources as legacy
read/write declarations. A read-only adapter rejects a write/read_write request
before any transfer or launch. Resolve access by **source identity**, not only
view type: requesting a direct mutable source and its read-only view in one run
is a conflict even though their types differ. Reject duplicate declarations
rather than silently creating two independently mutable replicas.

The initial binding operates within one world and synchronous invocation.
Cross-world shared sources, arbitrary aliases through captures, and externally
retained raw pointers are outside its guarantees; type identity cannot prove
their independence. Document this explicitly instead of claiming universal
alias detection or thread safety.

### Preparation and storage ownership

Separate reusable adapter configuration from target-local cache state. Each
world's device context owns the latter, keyed by binding identity. It must not
be reused on another context, including after a world copy. Copy configuration
and authoritative data, start with an empty cache, and reconstruct views.
Moving an idle world may transfer its cache with the associated context.

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
