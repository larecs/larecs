---
id: "0023"
title: "Explicit compile-time execution backend"
status: accepted
---

# Decision 0023: Explicit compile-time execution backend

## Context

Boolean target flags obscure kernel invocation intent. `on_device=True` also
silently selected host execution on builds without accelerator support.
Kernel offloading, transfer eligibility and lexical callable restrictions depend
on compile-time specialization. Issue [#206](https://github.com/larecs/larecs/issues/206)
requests explicit host/device choices.

## Decision

Export `ExecutionBackend` with `HOST` and `DEVICE` alternatives. Use the compile-time
parameter `backend: ExecutionBackend = ExecutionBackend.HOST` on all ordinary and
selected thin-kernel and value-taking callable entry points. Mojo 1.0 implements
enums as structs with named constants; reject values outside these alternatives
at compile time. No automatic choice is provided.

Thin kernels can select either backend. Value-taking callables require HOST,
with a compile-time diagnostic; explicit capture bindings remain supported by
thin device kernels. Threaded execution requires HOST and a thin kernel.

DEVICE raises when accelerator compilation support or a working world device
context is unavailable, including for empty matches. No kernel executes on the
host as fallback. Available device execution retains its existing type checks,
empty-match validation, transfer ownership and synchronous copy-back rules.

This supersedes decision 0015's boolean selection and fallback contract; its
host/device vocabulary and other renames remain accepted. Decisions 0002 and
0019 retain their transfer and threading contracts with this target spelling.

## Rationale

Compile-time selection eliminates unused target compilation and preserves the
existing kernel compilation model. Explicit failure makes a requested backend
reliable. Runtime selection would require compiling both targets and imposing
device restrictions on host-only kernels.

## Consequences

Replace `on_device=True` / `on_gpu=True` with `backend=ExecutionBackend.DEVICE`;
replace false with `backend=ExecutionBackend.HOST` or omit it. No compatibility
aliases remain during beta. Callers needing fallback must branch explicitly.
There is no new accelerator implementation or change to scheduling policy.

## Evidence

- [ECS-20](../requirements.md) and [public guide](../../src/guide/systems_scheduler.md#device-execution).
- `src/larecs/execution.mojo` and all four `run` overloads in `src/larecs/system.mojo`.
- `test/execution_backend_test.mojo` verifies the actual compilation target,
  exact selection membership, defaults, callables and unavailable device errors.
- `test/check_execution_backend_contracts.py` checks rejected boolean, legacy,
  runtime, invalid and device callable requests with positive host controls.
- Migrated GPU resource, capture, spatial, empty-range and selection tests retain
  hardware execution coverage; GPU tests omit debug information with SKIP_DEBUG.
