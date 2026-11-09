+++
type = "docs"
title = "Reuse unchanged device copies"
weight = 5
+++

Skip unchanged uploads only after the particle kernel passes
[host/device parity checks](../device). The per-world option is off by default
and [experimental](../../../reference/compatibility). It preserves synchronous
completion and eager copy-back of every written output.

## Keep the kernel independent of transfer policy

The stage uses plain particle types and the same read-only time resource.

{{< example file="particles/copy_reuse.mojo" region="model" >}}

`Time` is one resource value; `Position` and `Velocity` have separate columns in
each physical store. Reuse tracks those units, not individual scalar fields.

The kernel remains unchanged when you enable reuse.

{{< example file="particles/copy_reuse.mojo" region="kernel" >}}

`Position` is readable and writable, `Velocity` and `Time` are read-only.
A successful device call makes host and device copies current even for the
written `Position`, so the next identical call may skip its upload too.
Written output still downloads after every run; this is not persistent
unsynchronized device state.

The system chooses the target independently of the world's transfer policy.

{{< example file="particles/copy_reuse.mojo" region="system" >}}

Both default-transfer and reuse runs execute the same `Move` specialization.
This keeps the comparison's semantic work equal.

## Enable reuse and invalidate escaped writes

The sequence below enables {{< api World.reuse_device_copies >}}, reads without
invalidating, and then changes resource and component inputs.

{{< example file="particles/copy_reuse.mojo" region="sequence" >}}

`read` and read-only queries preserve reusable copies. `get` through mutable
storage conservatively advances a revision even if you only read it. The pointer
obtained before a later run does not trigger tracking when you subsequently
write through it. `invalidate_device[Time]()` after that write forces a refresh.
Reacquiring with `get` after each run is the preferred alternative. Neither
invalidation path permits mutation during a live invocation or makes an invalid
reference safe.

The data-validity sequence differs from allocation reuse.

![First use uploads, an unchanged revision reuses bytes, and a tracked write or explicit invalidation makes the next call upload again; allocation capacity persists.](/images/device-copy-reuse.svg)

*Retained capacity does not prove that its contents are current.*

The revision labels identify host data states. A current record skips an upload;
a changed record requires one. Downloaded outputs become current after successful
completion. A revision mismatch does not require discarding a large enough
allocation. This also applies to read-only adapted resources: validation and
leases still run, but a current copy skips the whole `prepare_device` hook and
reuses its descriptor and samples. Mutable adapters always prepare; explicit
captures upload every call.

## Know which operations advance revisions

| Data | Operations that can invalidate reusable bytes |
| --- | --- |
| Resource | Add/set, mutable `get`, and host/threaded/device runs declaring writable access. Removal discards its records. |
| Component type in a physical store | Mutable storage/row access, setters and kernels declaring writes, including exact selected ranges. |
| All columns affected by placement | Structural changes, spatial row permutations, partition transfers and store growth/replacement. |
| Escaped references or raw pointers | Untracked writes require resource-specific `invalidate_device[T]()` or {{< api World.invalidate_device_copies >}} for all copies. |

Component reuse also requires the same store incarnation, contiguous row range,
packed offset, and revision. Alternating filters or selections can change pack
offsets and cause reuploads despite unchanged host values. A world copy starts
with independent host owners and empty device records. Disabling reuse clears
records; it does not turn completion asynchronous. Failed queued invocations
invalidate their touched copies; an unusable world must still be replaced.

## Check both transfer policies

The driver compares the full mutation sequence, including eager host results,
against default device transfers and a host baseline.

{{< example file="particles/copy_reuse.mojo" region="check" >}}

Every executed path ends at `(4.5, 7.0)`. From the repository root, run
`pixi run mojo run -I src examples/particles/copy_reuse.mojo`. A device PASS
confirms actual default/reuse execution and parity; a hardware SKIP covers only
the host mutation sequence. This example checks correctness, not upload-byte
counts. The [device-copy tests](https://github.com/larecs/larecs/blob/main/test/device_copy_reuse_test.mojo)
and [column tests](https://github.com/larecs/larecs/blob/main/test/device_column_reuse_test.mojo)
check transfer records and bytes separately.

## Troubleshooting

| Symptom | Fix |
| --- | --- |
| Device reads old values | Reacquire mutable references after each run, or invalidate after an escaped write. Disable reuse while diagnosing parity. |
| Uploads remain frequent | Use `read` for observation; inspect declared writes, changing filters/ranges, and spatial maintenance. A stable allocation is not a stable data record. |
| Written data still downloads | This is required eager copy-back. Measure complete calls, including downloads and synchronization. |

[Measure complete simulation steps](../../performance/measure) before retaining
this optimization.

{{< example file="particles/copy_reuse.mojo" full=true >}}

[Device-copy validity](../../../inside/architecture/transfers#device-copy-validity)
explains storage identity, store incarnations, packed offsets, and failure invalidation.
