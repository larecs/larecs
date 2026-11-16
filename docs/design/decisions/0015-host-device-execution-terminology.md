---
id: "0015"
title: "Host/device execution terminology and beta API renames"
status: accepted
---

# Decision 0015: Host/device execution terminology and beta API renames

## Context

The execution API describes host storage and device transfers, but its names
previously tied those roles to CPU/GPU hardware. The library is in beta, and
device execution remains experimental under decision 0002. Future accelerators
could fill the device role without being GPUs.

## Decision

- Use host/device for execution roles, memory, bindings, and transfer boundaries.
- Rename `on_gpu` to `on_device` in both thin and lexical `run` overloads on
  `SystemContext` and `EntitySelection`. Lexical overloads remain host-only.
- Rename `GPUComponentType` and `GPUResourceType` to `DeviceComponentType`
  and `DeviceResourceType`, and `constrain_gpu_safe_components` and
  `constrain_gpu_safe_resources` to `constrain_device_safe_components` and
  `constrain_device_safe_resources`.
- Rename internal `_bind_cpu_resources` and `_cpu_kernel_context` to
  `_bind_host_resources` and `_host_kernel_context`.
- Make these direct beta API renames without compatibility aliases. Update
  callers, diagnostics, tests, benchmarks, and user guides together.
- Retain CPU/GPU for hardware descriptions, GPU thread/grid facilities,
  toolchain requirements, measured hardware evidence, and upstream identifiers.
  Preserve hardware test filenames and benchmark result identifiers.

## Rationale

The names describe the API's execution and transfer roles without committing
to a hardware family. This follows the host/device distinction in the
[Mojo GPU package](https://docs.modular.com/mojo/std/gpu/), which still uses
GPU names for GPU-specific facilities. Making the change during beta avoids
maintaining two spellings before the stable API is established.

## Consequences

Existing callers must update the renamed parameters and imports. This changes
names only: the current backend still uses supported GPU accelerators through
`DeviceContext`. No AI accelerator or other new backend support is introduced.
Raw-byte transfer restrictions, synchronization, host fallback when accelerator
support is unavailable, and host-only lexical capture restrictions remain as
specified by [decision 0002](0002-gpu-system-execution.md). The resource alias
does not replace the existing trivial-movability validation of resources.

## Evidence

- [Execution requirements ECS-05, ECS-08, ECS-09, and ECS-10](../requirements.md).
- [`system.mojo`](../../../src/larecs/system.mojo),
  [`component.mojo`](../../../src/larecs/component.mojo), and
  [`resource.mojo`](../../../src/larecs/resource.mojo).
- [Systems guide](../../src/guide/systems_scheduler.md#device-execution).
- [`cpu_execution_test.mojo`](../../../test/cpu_execution_test.mojo),
  [`resource_test.mojo`](../../../test/resource_test.mojo), and
  [`gpu_entity_selection_test.mojo`](../../../test/gpu_entity_selection_test.mojo).
