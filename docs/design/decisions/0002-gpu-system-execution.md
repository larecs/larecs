---
id: "0002"
title: "Device system execution and transfer boundaries"
status: accepted
---

# Decision 0002: Device system execution and transfer boundaries

## Context

`SystemContext.run(..., on_device=True)` runs the same filtered kernel source as
the host path. Matching entities may occupy multiple archetypes, while a device
kernel needs a compact device-side row range. Host and device columns also have
different ownership and lifetime rules.

## Decision

[Decision 0015](0015-host-device-execution-terminology.md) records the beta
host/device API renames; this decision's execution and transfer rules remain
unchanged.

- Preserve one user-authored kernel implementation for host and device execution.
  Target selection belongs at the `run` call, not in a separate kernel body.
- Pack matching archetype rows into device component columns at distinct
  offsets, launch over the packed length, and scatter written rows back to
  their original host locations. Empty matches do not launch a kernel.
- The filter declares component access: `include[T]` reads and writes,
  `read[T]` uploads without downloading, and `write[T]` downloads without
  uploading the old value. Component access is checked against that filter.
- Reuse device column allocations when possible, but transfer the declared
  readable/writable values for each call. Synchronize before returning so
  callers observe completed writes and may safely reuse host state.
- Transfer only component and resource types supported by the current raw-byte
  device path. Heap-backed resources need a separate ownership and encoding
  design. Explicit captures and required resources follow their declared
  binding and copy-back rules.
- Use the [grid-stride iteration decision](0003-grid-stride-entity-iteration.md)
  to partition packed rows among GPU threads.

## Rationale

Distinct offsets prevent later archetypes from overwriting earlier ones in a
flat device column. Access modes avoid transfers that cannot affect the kernel
result. Persistent column allocations avoid repeated allocation work without
claiming that component values are resident or synchronized across calls.

## Consequences

Device execution is experimental and may cost more than host execution for small
or memory-bound workloads. Host/device transfer and synchronization remain in
the call path. Adding residency or a different transfer model requires a new
decision covering invalidation, ownership, and visibility to host callers.
The portability requirement also applies to future kernel APIs. The current
host-only lexical closure overload and device transfer type restrictions are gaps
to resolve or reject explicitly, not evidence that every host callable already
runs on a device.

[Decision 0013](0013-cluster-local-partition-blocks.md) extends host placement
with opt-in partition blocks. Packing and scattering traverse each matching
physical block/range through these same transfer boundaries; logical component
filters and exact selected membership remain unchanged.

[Decision 0018](0018-portable-resource-adapters.md) adds source-declared read-only
resource adapters and access modes. It retains the packing and synchronous
boundaries here while staging high-level IO in owned buffers, publishing only
after completion, and rejecting further execution after unconfirmed failure.

## Evidence

The implementation is in `src/larecs/system.mojo`,
`src/larecs/device_storage.mojo`, and `src/larecs/filter.mojo`. Current
regression coverage includes `test/gpu_component_access_test.mojo`,
`test/gpu_device_storage_test.mojo`, `test/gpu_entity_selection_test.mojo`,
and `test/gpu_resource_test.mojo`. The reproducible workload is
`benchmark/gpu_system_benchmark.mojo`. See
[ECS-05, ECS-08, and ECS-10](../requirements.md)
for cross-cutting requirements.
