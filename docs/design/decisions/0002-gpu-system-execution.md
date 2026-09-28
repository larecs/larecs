# Decision 0002: GPU system execution and transfer boundaries

Status: Accepted for the current experimental GPU API. Device residency,
pinned-download staging, ahead-of-time compilation, and launch tuning in the
[optimization notes](../background/gpu-system-execution-optimization.md) are
proposals, not part of this decision.

## Context

`SystemContext.run(..., on_gpu=True)` runs the same filtered kernel source as
the CPU path. Matching entities may occupy multiple archetypes, while a GPU
kernel needs a compact device-side row range. Host and device columns also have
different ownership and lifetime rules.

## Decision

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
  GPU path. Heap-backed resources need a separate ownership and encoding
  design. Explicit captures and required resources follow their declared
  binding and copy-back rules.
- Use the [grid-stride iteration decision](0003-grid-stride-entity-iteration.md)
  to partition packed rows among GPU threads.

## Rationale

Distinct offsets prevent later archetypes from overwriting earlier ones in a
flat device column. Access modes avoid transfers that cannot affect the kernel
result. Persistent column allocations avoid repeated allocation work without
claiming that component values are resident or synchronized across calls.
Historical Apple M4 measurements and the original optimization sequence are
preserved in the [working notes](../background/gpu-system-execution-optimization.md);
they are not a current performance baseline.

## Consequences

GPU execution is experimental and may cost more than CPU execution for small
or memory-bound workloads. Host/device transfer and synchronization remain in
the call path. Adding residency or a different transfer model requires a new
decision covering invalidation, ownership, and visibility to host callers.

## Evidence

The implementation is in `src/larecs/system.mojo`,
`src/larecs/device_storage.mojo`, and `src/larecs/filter.mojo`. Current
regression coverage includes `test/gpu_component_access_test.mojo`,
`test/gpu_device_storage_test.mojo`, `test/gpu_entity_selection_test.mojo`,
and `test/gpu_resource_test.mojo`. The reproducible workload is
`benchmark/gpu_system_benchmark.mojo`. See [ECS-05 and ECS-08](../requirements.md)
for cross-cutting requirements.
