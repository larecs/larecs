+++
type = "docs"
title = "Bindings, transfers, and revisions"
weight = 5
+++

A {{< api ResourceStorage >}} owns one source value per resource type.
An invocation validates its {{< api Resources >}} declarations, leases the
sources, and retains prepared views until completion. Leases reject reentrant
lookup, replacement, or removal of bound sources. They protect lifetime;
they do not synchronize workers or repair escaped aliases.

## Sources and target-local views

Ordinary resources bind directly on the host. Device transfer accepts only
supported plain representations. Recursive field checks reject owning,
pointer-bearing, or nontrivial values; `PlainValue` permits an author-declared
opaque representation only after trivial copy/move/destruction checks. That
declaration makes the author responsible for pointer-free nested data.

A {{< api DevicePassableResource >}} source instead declares a stateless
{{< api ResourceAdapter >}}. Its host view borrows source data; its device
view refers to adapter-managed target allocations. `read` selects
`View[False]`; `write` and `read_write` select `View[True]`.
Mutable preparation distinguishes fresh initialized output from preserved
contents. It runs once per invocation before any range/chunk/launch, and
finalization runs once after successful execution/publication, including
empty matches. Mutable access requires adapter capability flags; threaded
and device mutation also require concurrent-mutation support.

Read-only adapters guarantee concurrent readability of their views and
reachable data. Owning sources stay on the host; copying their pointer bytes
would not transfer the owned allocation. This is why a portable buffer or grid
has a separate kernel representation.

## Packing and publication

Component access declarations determine the transfer directions in this
adaptation of the thesis's device-memory figure.

![Two selected host ranges pack into Position read-write and Velocity read-only device columns; only written Position spans scatter back and host gaps remain unchanged.](/images/device-transfer.svg)

*Read access supplies input; write access schedules output publication.*

Readable columns upload each selected span to its packed offset. Write-only
columns allocate output without uploading old bytes, so kernels must initialize
every processed row before reading it. After execution, only declared written
columns download and scatter back. Resource and explicit-capture outputs use
the same invocation queue. Selection gaps stay untouched.

`_TransferFrame` snapshots uploads in native host buffers and retains download
staging buffers with eventual host destinations. Queued copies therefore do
not retain caller-owned upload memory. The executor synchronizes the queue,
publishes staged bytes, commits resource/column records, then finalizes
adapters. Errors drain submitted work before releasing owners. If completion
cannot be confirmed, the world becomes unusable for further execution.
Already performed host writes and published outputs are not rolled back.

## Device-copy validity

Buffer capacity reuse is independent of content reuse. By default, readable
inputs upload every invocation. Experimental `World.reuse_device_copies`
also retains successful transfer records, as the figure shows.

![A matching revision skips an unchanged upload, mutable host access makes it stale, the next device call uploads again, and declared outputs always download.](/images/device-copy-reuse.svg)

*Skipping uploads requires matching validity metadata; output publication stays eager.*

Resource revisions come from an increasing storage counter. Mutable `get`,
`add`/`set`, declared host writes, and successful device writes advance them;
`read` does not. Reuse still validates and leases the source. A current
read-only adapted copy can skip `prepare_device`; mutable adapted sources
always prepare and never reuse their contents.

A column record identifies storage identity, physical-store slot, never-reused
store incarnation, column revision, first row, row count, and packed offset. A mutation,
row movement, reclaimed-slot replacement, or changed packing offset invalidates
the relevant match. Written outputs still download. Failed calls invalidate
touched records; disabling reuse, removal, and copying a world discard relevant
records. Moves preserve owned state.

Tracked mutable exposure invalidates conservatively before the caller writes.
A later edit through an escaped reference or raw pointer cannot advance the
counter automatically: it requires explicit invalidation. Revisions are validity
metadata, not alias tracking or a promise of persistent device-only state.

Implementation: {{< source "resource.mojo" >}},
{{< source "resource_adapter.mojo" >}}, {{< source "device_storage.mojo" >}},
{{< source "system.mojo" >}}.
Evidence: {{< repo "test/resource_adapter_test.mojo" >}},
{{< repo "test/mutable_resource_adapter_test.mojo" >}},
{{< repo "test/device_copy_reuse_test.mojo" >}},
{{< repo "test/device_column_reuse_test.mojo" >}}.
The [resource reference](../../../reference/resources) defines author obligations
and the [copy-reuse guide](../../../guide/execution/copy_reuse) shows invalidation.
