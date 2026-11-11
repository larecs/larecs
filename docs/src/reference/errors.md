+++
type = "docs"
title = "Errors and migration"
weight = 7
+++

Read each generated operation's **Raises** and **Constraints** before handling a failure. Constraints reject invalid programs at compile time; runtime errors report invalid state or execution failures.

| API or condition | Meaning and response |
| --- | --- |
| {{< api LarecsError >}} | Variant containing typed ECS errors and general `Error` failures. Inspect the specific error rather than assuming every failure is an invalid entity. |
| {{< api EntityError >}}, {{< api ComponentError >}} | Invalid/stale entity or component membership errors. Recheck the handle generation and requested composition. |
| {{< api WorldError >}} | Includes structural lock exhaustion, a locked world and negative batch counts. Release queries/selections before structural changes; pass a nonnegative count. |
| Device setup or synchronization failure | `run` raises; it does not retry on host. Fix device availability or explicitly select HOST. |
| Invalid resource/capture access | Check declarations, presence, access modes and binding order. Synchronization cannot repair a declaration mismatch. |
| `Threaded resources require explicit read access` (compile error) | Ordinary threaded resources must declare `read`; mutable adapters need concurrent-mutation support. See [threaded restrictions](../../guide/execution/threaded#troubleshooting). |
| `Cluster selection requires clean spatial maintenance` | Release live selections/queries and maintain explicitly before selecting the next cluster. See [spatial recovery](../../guide/spatial_locality/maintain#execute-and-troubleshoot). |
| Device reads stale data with reuse enabled | Reacquire mutable references after each run or invalidate after escaped writes. See [copy-reuse recovery](../../guide/execution/copy_reuse#troubleshooting). |
| `TryAccess.is_acquired()` is false | The guard attempt is Busy. Record required unfinished work for a later pass; there is no automatic retry. See [shared-write alternatives](../../guide/execution/shared_writes). |

A failing kernel call is not a transaction: do not infer rollback of writes already performed. Scoped selections release locks on exit, including exceptional exit. Failure effects specific to an operation remain in its defining declaration.

## Migration spellings

Older examples may use direct `World` entity operations or boolean execution-target flags. Current single-entity setup uses `world.storage`; scheduled application updates use `SystemContext`. Select targets with `backend=ExecutionBackend.HOST` or `backend=ExecutionBackend.DEVICE`. Consult {{< api SystemContext.run >}} for the current overloads.

Resource adapters written for the read-only adapter API need three changes:

1. Replace `comptime View = MyView` with `comptime View[mut: Bool] = MyView`.
2. Change `bind_host` and `prepare_device` to return `Self.View[False]`.
3. Remove `comptime KernelView = MyView` from the source. `KernelView` remains an alias for `View[False]`.

Adapters that do not opt into mutation keep their behavior; mutable declarations of them fail to compile with "DevicePassableResource mutable access requires Adapter.supports_mutation".

The [changelog](https://github.com/larecs/larecs/blob/main/changelog.md) records release changes. The development reference does not imply that an unreleased declaration exists in a previously installed package.
