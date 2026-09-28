# Decision 0004: GPU dictionary resource views

Status: Proposed. The implementation on `future/gpu-dictionary-resources` is a
prototype and is not part of the current release contract.

## Context

The accepted GPU execution path transfers ordinary resources as raw bytes.
Mojo `Dict` owns host memory, so copying its struct bytes does not make its
keys and values accessible to a GPU. [Decision 0002](0002-gpu-system-execution.md)
requires a separate transfer design for such resources. [ECS-10](../requirements.md)
also requires one user-authored kernel body for CPU and GPU execution.

## Decision

Propose a `GPUResource` trait with a trivial `ViewType` and an `encode()` method.
`ResourceEncoder` owns packed host tables for CPU execution and uploaded
device buffers for GPU execution. A kernel declares the host resource type in
`Resources[...]` and uses the ordinary `context.resources.get[T]()` call. That
call returns `T.ViewType` on both targets. No dictionary-specific method is
added to `KernelContext` or `ResourceStorage`.

The prototype provides `Int32DictResource` (`Int32` keys and values) and
`StringDictResource` (`String` keys and `Int32` values). Their host dictionaries
live in `.entries`; their views expose `get_or(key, default)`. These wrappers
may be fields of another resource struct. Such a struct supplies its own
trivial view and `encode()` method to map the fields.

The proposed views are read-only. Host edits to `.entries` are packed on the
next run. `GPUResource` view changes are not decoded or copied back after a
CPU or GPU run, even though the generic getter currently yields a mutable
reference. Insertion, removal, and updates to existing values inside kernels
are outside this proposal.

## Rationale

An explicit view makes device pointers and lifetimes visible in the transfer
path. Using one view type on both targets preserves the kernel signature. A
wrapper field lets an enclosing resource opt in without making a host `Dict`
itself appear device-safe. Explicit `encode()` implementations keep ownership
and field conversion reviewable while the API is experimental.

## Consequences

- CPU runs pack temporary tables; GPU runs upload fresh tables. Both add work
  per invocation, so throughput and transfer costs need measurement before
  release.
- Kernel writes to a view or its value buffer are discarded. A later design
  must specify existing-key updates, host copy-back, and concurrent GPU write
  semantics before exposing mutation.
- Other dictionary key/value types and general heap-backed resource fields
  remain unsupported without their own view and encoder path.
- Composite view storage currently requires alignment no greater than eight
  bytes. This restriction and the mutable-reference/read-only mismatch need
  review before acceptance.
- The API names and shape may change before release. The current public guide
  continues to describe the accepted raw-byte resource path.

## Evidence

The prototype is in `src/larecs/resource.mojo`,
`src/larecs/device_storage.mojo`, and `src/larecs/system.mojo`. Focused coverage
is in `test/resource_test.mojo` and `test/gpu_resource_test.mojo`, including a
composite resource with multiple dictionary fields run on CPU and Apple GPU.
The work required for release is tracked in the
[roadmap](../../roadmap.md#support-heap-backed-gpu-resources). The accepted
current boundary remains [ECS-08](../requirements.md).
