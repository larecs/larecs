+++
type = "docs"
title = "Use portable resources"
weight = 3
+++

Read an owning sample collection through the same particle kernel on host and
device. Start with [shared resources](../../shared_resources) and
[device selection](../device). Adapter-backed device execution and mutable
adapters follow the [experimental status](../../../reference/compatibility).
This stage uses read-only views; kernel outputs remain per-entity components.

## Separate the owner from the kernel view

The particle fields stay plain; time remains an ordinary read resource.

{{< example file="particles/portable_resources.mojo" region="model" >}}

These types have no heap ownership. The new resource sources below instead own
collections and expose a different representation inside kernels.

Use {{< api BufferResource >}} for a contiguous scalar buffer. Add a custom
{{< api DevicePassableResource >}} only when the kernel needs a domain-specific
view, such as the last sample of a rectangular grid.

{{< example file="particles/portable_resources.mojo" region="owner_view" >}}

`Samples` owns its host collection and supplies the built-in immutable
{{< api ReadBuffer >}} with length and bounds-checked indexing. Do not index an
empty buffer. `Grid` owns its `List`; `GridView` borrows samples through a
pointer and exposes `last()`. Its dimensions must describe a nonempty grid.
The pointer in a view is target-local: it refers to host memory during a host
run and device memory during a device run.

## Implement validation and target preparation

The stateless {{< api ResourceAdapter >}} checks the current owner and prepares
the same descriptor type for each target.

{{< example file="particles/portable_resources.mojo" region="adapter" >}}

`validate` rejects zero dimensions, overflow, and inconsistent counts before
binding either target, including empty entity matches. `bind_host` points into
the retained source, never a temporary list. Its untracked origin makes the
owner/lifetime obligations explicit; it does not transfer ownership.

`prepare_device` uses {{< api ResourceDeviceCache >}} slot 0 for samples.
`cache.upload` snapshots supported pointer-free trivial samples in owned
staging before enqueueing. Larecs uploads the descriptor separately, using
reserved slot `-1`. Give additional arrays distinct nonnegative stable slots;
do not enqueue copies from external host pointers or temporary allocations.
The cache belongs to the source type, world, and device context. It retains
allocation capacity; by default preparation still uploads current data each run.
[Copy reuse](../copy_reuse) can skip read-view preparation when revisions match.

## Request the source type and receive its view

Both `Resources` and the getter name the owning source type.

{{< example file="particles/portable_resources.mojo" region="kernel" >}}

Inside `move`, `get[Samples]()` returns `ReadBuffer` and `get[Grid]()` returns
`GridView`, both immutable. Outside execution, `world.resources.get[Grid]()`
returns the owning `Grid`. Lookup uses source identity, so two owners may share
a view type without becoming the same resource. Adapters register automatically
when the source is added or inserted with `set`; there is no adapter factory.

The driver adds both sources, changes the grid owner between runs, and checks
validation without matching entities.

{{< example file="particles/portable_resources.mojo" region="check" >}}

The first step uses scale `1 + 2` and ends at `x=0.75`; the edited owner changes
the next scale to `1 + 3` and ends at `(1.75, 3.5)`. Each target runs a fresh
simulation. The device PASS line confirms actual sample transfer and execution;
the SKIP line means only host validation ran. From the repository root, execute
`pixi run mojo run -I src examples/particles/portable_resources.mojo`.

## Keep sources and views valid until completion

Larecs validates sources, leases them, and retains descriptors until synchronous
completion, including the join of threaded host workers. Reentrant lookup,
replacement, or removal of a bound source raises. Copying/moving/destroying
leased storage through an escaped alias aborts. Neither a view, its pointers,
nor references obtained from it may escape the invocation.

Every read view and all reachable storage must support concurrent reads without
hidden mutation. Escaped aliases must not mutate, resize, relocate, or free the
backing collection while a run uses it. An immutable pointer field alone does
not establish that contract. Read adapters bind once on the coordinating host
caller for threaded execution, then share the retained descriptor until join.

## Use a writer view only when the adapter supports it

This `GridAdapter` is read-only. `Resources[Grid]()` means read-write and is
rejected; declare `read` explicitly. For shared output, first consider
[per-row results and a later reduction](../shared_writes).

Current mutable adapters can opt into `supports_mutation` for sequential host
writes and additionally `supports_concurrent_mutation` for threaded/device
writes. These capabilities are author guarantees: an exclusive source lease
does not prevent races among workers of one invocation. `write` selects fresh,
adapter-initialized output; `read_write` preserves it. The descriptor remains
immutable; its methods control backing writes. Preparation and finalization run
once per invocation, even for empty matches, and mutable adapters prepare on
every call despite copy reuse. The [adapter reference](../../../reference/resources)
and [checked scatter example](https://github.com/larecs/larecs/blob/main/examples/scatter_resource.mojo)
cover the hooks and atomic slot-reservation pattern.

## Troubleshooting

| Failure or restriction | Fix |
| --- | --- |
| Grid validation error | Match dimensions and sample count before running. Empty entity matches do not bypass validation. |
| Mutable declaration rejected | Use explicit `read` for these sources, or implement the writer protocol and required capabilities. Ordinary device write-only resources remain unsupported. |
| Invalid or stale view pointer | Return target-local, owner/cache-backed memory; keep aliases from invalidating it. Do not byte-transfer a host pointer as an ordinary resource or capture. |
| Unexpected stale samples with reuse enabled | Reacquire the owner through `get` after each run, or explicitly invalidate after an escaped-reference write. |
| Adapter finalizer raises | Published outputs remain; the invocation is not a transaction. See [device failure behavior](../device#account-for-transfers-and-completion). |

{{< example file="particles/portable_resources.mojo" full=true >}}

[Binding internals](../../../inside/architecture/transfers#sources-and-target-local-views)
explains leases, adapter descriptors, and source/view lifetimes.
