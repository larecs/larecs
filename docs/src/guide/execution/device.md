+++
type = "docs"
title = "Execute on a device"
weight = 1
+++

Run the particle movement kernel on an explicitly selected accelerator, then
check the result against an independent host run. Start with
[systems and kernel access](../../systems_kernels) and
[shared time](../../../start/shared_configuration). Device execution is
[experimental](../../../reference/compatibility); use the pinned Mojo/MAX
environment and a working supported accelerator.

## Define a transferable movement stage

This stage keeps the particle names and uses `Float32` arithmetic, including on
host, so its arithmetic also compiles for Apple GPUs.

{{< example file="particles/device.mojo" region="model" >}}

`Position` and `Velocity` declare `TrivialRegisterPassable`, the component
transfer requirement. `Time` is an ordinary resource: its recursively checked,
pointer-free representation qualifies without that trait. A component trait
check does not establish resource eligibility, and a host pointer field does
not become a device allocation through byte copying.

Declare the readable inputs and writable position before selecting a target.

{{< example file="particles/device.mojo" region="kernel" >}}

`move` reads `Velocity` and `Time` and updates `Position`. The filter controls
component matching and access; `Resources` separately declares resource access.
`include` uploads and downloads the component, `read` uploads only, and `write`
downloads only. A write-only component supports `set`, not `get`; initialize it
for every visited row because its previous host bytes are not uploaded.

## Select the target in the system

The system specializes {{< api SystemContext.run >}} for a
{{< api ExecutionBackend >}} value.

{{< example file="particles/device.mojo" region="system" >}}

`Move[ExecutionBackend.HOST]()` uses sequential host execution, also the default
when `backend` is omitted. `Move[ExecutionBackend.DEVICE]()` requests a device.
The choice is compile-time; a runtime choice needs an explicit branch calling
each specialization. The same choice is available on
{{< api EntitySelection.run >}} for exact selected ranges.

The execution mapping changes how often code outside the entity loop runs.

![Sequential host calls each matching store, threaded host calls disjoint chunks, and device threads stride through packed matching rows.](/images/execution-mapping.svg)

*One row loop, three invocation mappings.*

Store A and Store B are physical stores, which can belong to the same logical
archetype. Sequential host calls cover stores or exact selected ranges;
threaded calls may split those ranges. Device threads divide the packed rows
in one launch using grid-stride iteration. Each matched row is visited once;
row indices are local to the prepared context, never stable entity IDs.

## Account for transfers and completion

By default, every device call uploads all readable columns and resources.
The transfer path packs only matching ranges and scatters writable results
back to their original host stores.

![Readable Position and Velocity ranges pack from two host stores into device columns; only written Position scatters back after synchronization.](/images/device-transfer.svg)

*Access declarations determine transfer directions.*

The upload arrows carry both readable columns; the return arrows carry only
`Position`. Gaps outside a selection remain untouched. Resource views and
capture values bind separately from these columns. Allocation capacity can
persist between calls; skipping unchanged data uploads requires the separate
[copy-reuse option](../copy_reuse).

`run` returns after the launch, synchronization, and writable component,
read-write resource, and mutable-capture copy-back finish. The next system sees
those host values. Downloads use owned staging and publish after successful
synchronization. A transfer or synchronization failure discards unpublished
staged outputs and drains the queue; if completion remains unknown, the world
rejects further execution. Host effects are not rolled back. An adapter finalizer
can raise after publication; its published outputs remain.

## Execute and compare independent runs

The checked driver seeds 37 movers and an unmatched marker, runs two steps per
target, and checks every coordinate before comparing sums.

{{< example file="particles/device.mojo" region="parity" >}}

Each mover ends at `(0.5, 1.0)` and the marker stays at `(-3, -3)`. The non-block
multiple exercises device iteration beyond a trivial single-row launch.
`has_accelerator()` gates this program's optional validation; it is not a Larecs
fallback. Once the program attempts DEVICE, initialization or execution errors
propagate. The no-support branch instead checks that even an empty DEVICE
request raises.

From the repository root, run the checked source:

```sh
pixi run mojo run -I src examples/particles/device.mojo
```

`PASS: actual device execution and host/device parity` confirms executed device
work. `SKIP: device parity ...` confirms only the host path; compilation or a
hardware skip does not validate the accelerator result.

## Troubleshooting and limits

| Failure or restriction | Response |
| --- | --- |
| DEVICE unavailable | DEVICE raises even with no matching rows. Fix the accelerator/toolchain or explicitly choose HOST. There is no automatic fallback. |
| Empty match on a working device | Required resources and adapters still validate; no device allocation, upload, or launch occurs. Captures stay unchanged. Mutable adapters still prepare/finalize host output. |
| Component transfer rejection | Use components satisfying the device transfer check; keep owning collections on the host. Only accessed component types are checked. |
| Ordinary resource rejection | Use recursively pointer-free trivial values, or an [adapter](../portable_resources) for an owner. `PlainValue` is a trusted declaration for opaque pointer-free trivial fields, not permission to transfer pointers. |
| Resource access rejection | Ordinary device resources allow `read` and `read_write`, not `write`. Mutable shared values require race-free writes. |
| Closure or threaded/device combination rejected | Device entry points are thin kernels. Lexical callables require sequential HOST; `threaded=True` requires HOST. |
| Missing resource, including on an empty match | Add every declared source during setup. Device availability is checked before resource preparation. |

Keep expensive work per particle; transfers and preparation can dominate a small
kernel. [Measure complete simulation steps](../../performance/measure) before
choosing a backend.

{{< example file="particles/device.mojo" full=true >}}
