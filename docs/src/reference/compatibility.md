---
title: Compatibility and status
type: docs
---

This reference describes the development checkout, currently Larecs 1.0 beta. Public APIs may change before stable 1.0.0. After stable release, public APIs follow semantic versioning unless explicitly experimental. Threaded host and device execution are experimental.

| Contract | Sequential host | Threaded host | Device |
| --- | --- | --- | --- |
| Thin kernel | Supported; default | `threaded=True` | `backend=ExecutionBackend.DEVICE` |
| Value-taking callable | Supported, including lexical captures | Rejected at compile time | Rejected at compile time |
| Components | Host `ComponentType`, including nontrivial ownership | Pointer-free trivial plain values | `TrivialRegisterPassable` transfer check |
| Ordinary resources | Host resource traits; declared access | Explicit read-only pointer-free plain values | Recursively checked pointer-free plain values |
| Adapted resources | Access-selected host views | Mutable views require concurrent-mutation support | Access-selected device views and adapter-managed transfers |
| Explicit captures | Read-only and mutable slots | Unsupported | Device-safe values and synchronous copy-back |
| Scheduling | One invocation per nonempty matching store | Concurrent chunks; sequential below threshold or with one worker | One launch across matching rows |
| Completion | Synchronous | Synchronous | Synchronous, including written data copied back |

Eligibility checks run independently of threaded worker count and fallback thresholds. Setting one worker does not allow nontrivial components, mutable ordinary resources, or captures through the threaded path. Device selection never falls back to host.

The defining contracts are {{< api SystemContext.run >}}, {{< api component.constrain_device_safe_components >}}, {{< api resource.constrain_device_safe_resources >}}, and {{< api DevicePassableResource >}}. Adapter-backed sources control their view and transfer lifecycle; a component's device eligibility does not establish a resource's eligibility.

Readable device data uploads when the cached copy is stale. Write-only columns skip upload and must be fully written. Read-only reuse therefore depends on revision tracking, not merely on calling the same kernel again.
