+++
type = "docs"
title = "Compatibility and status"
weight = 6
+++

This reference describes the development checkout, currently Larecs 1.0 beta. Public APIs may change before stable 1.0.0. After stable release, public APIs follow semantic versioning unless explicitly experimental. Threaded host and device execution, mutable resource adapters, and device-copy reuse are experimental.

## Target support

| Contract | Sequential host | Threaded host | Device |
| --- | --- | --- | --- |
| Thin kernel | Supported; default | `threaded=True` | `backend=ExecutionBackend.DEVICE` |
| Value-taking callable | Supported, including lexical captures | Rejected at compile time | Rejected at compile time |
| Components | Host `ComponentType`, including nontrivial ownership | Pointer-free trivial plain values | `TrivialRegisterPassable` transfer check |
| Ordinary resources | Host resource traits; declared access | Explicit read-only pointer-free plain values | Recursively checked pointer-free plain values |
| Portable resources | Access-selected host views | Mutable views require concurrent-mutation support | Access-selected device views and adapter-managed transfers |
| Explicit captures | Read-only and mutable slots | Unsupported | Device-safe values and synchronous copy-back |
| Scheduling | One invocation per nonempty matching store | Concurrent chunks; sequential below threshold or with one worker | One launch across matching rows |
| Completion | Synchronous | Synchronous | Synchronous, including written data copied back |

A *thin kernel* is a named `def` function, such as `move`, that `run` receives as a compile-time parameter (`context.run[move]()`); it captures no local variables. Eligibility checks run independently of threaded worker count and fallback thresholds. Setting one worker does not allow nontrivial components, mutable ordinary resources, or captures through the threaded path.

The defining contracts are {{< api SystemContext.run >}}, {{< api component.constrain_device_safe_components >}}, {{< api resource.constrain_device_safe_resources >}}, and {{< api DevicePassableResource >}}. Portable resource sources control their view and transfer lifecycle; a component's device eligibility does not establish a resource's eligibility.

By default, readable device data uploads on every call. With `world.reuse_device_copies(True)`, it uploads only when the cached copy is stale. Write-only columns skip upload and must be fully written. Read-only reuse therefore depends on revision tracking, not merely on calling the same kernel again. Device-copy reuse never skips written output copy-back.

Standalone atomic and guard primitives exist, with Apple device restrictions. Automatic kernel synchronization bindings and deferred retries are unimplemented.

## Cross-cutting limits

### No device fallback

`backend=ExecutionBackend.DEVICE` never falls back to host execution. Without accelerator support, or when the world's device context failed to initialize, `run` raises, even when no rows match. Once a device run starts, initialization, transfer, and execution errors propagate to the caller. To use the host when no device is available, branch explicitly, for example on `has_accelerator()`, and call the `ExecutionBackend.HOST` specialization.

### Empty queries and selections hold structural locks

A live query, storage batch range, or entity selection holds a structural lock even when it matched nothing or its cursor is exhausted. While any lock is held, entity creation and deletion, component additions and removals, spatial maintenance, and cluster selection raise a locked-world error. The exception is a selection's own `add`, `remove`, and `replace`, which work while that selection holds the world's only lock; see {{< api EntitySelection >}}. End the lock first: consume the query with `^`, let it go out of scope, or close the selection's `with` block.

### Row indices are not entity IDs

A kernel row's `idx` counts from zero within one kernel invocation: one physical store, one selected range, or one threaded chunk. On a device, it is the row's offset in the packed rows of one launch. The same entity can have a different `idx` in the next call, because structural changes, spatial maintenance, chunking, and packing all change it. Identify entities with {{< api Entity >}} handles, and do not index shared output with `idx`.

### Structural locks are not mutexes

A structural lock keeps rows in place while a query, selection, or kernel uses them. A resource lease keeps a resource source alive and in place during a kernel call. Neither serializes threads, makes concurrent writes race-free, or protects against aliases obtained before the call, such as a pointer kept from an earlier `get`. Shared writes need per-row output, a single writer, or a [synchronization primitive](../spatial_sync#synchronization-primitives).
