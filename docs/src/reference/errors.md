---
title: Errors and migration
type: docs
---

Read each generated operation's **Raises** and **Constraints** before handling a failure. Constraints reject invalid programs at compile time; runtime errors report invalid state or execution failures.

| API or condition | Meaning and response |
| --- | --- |
| {{< api LarecsError >}} | Variant containing typed ECS errors and general `Error` failures. Inspect the specific error rather than assuming every failure is an invalid entity. |
| {{< api EntityError >}}, {{< api ComponentError >}} | Invalid/stale entity or component membership errors. Recheck the handle generation and requested composition. |
| {{< api WorldError >}} | Includes structural lock exhaustion, a locked world and negative batch counts. Release queries/selections before structural changes; pass a nonnegative count. |
| Device setup or synchronization failure | `run` raises; it does not retry on host. Fix device availability or explicitly select HOST. |
| Invalid resource/capture access | Check declarations, presence, access modes and binding order. Synchronization cannot repair a declaration mismatch. |

A failing kernel call is not a transaction: do not infer rollback of writes already performed. Scoped selections release locks on exit, including exceptional exit. Failure effects specific to an operation remain in its defining declaration.

## Migration spellings

Older examples may use direct `World` entity operations or boolean execution-target flags. Current single-entity setup uses `world.storage`; scheduled application updates use `SystemContext`. Select targets with `backend=ExecutionBackend.HOST` or `backend=ExecutionBackend.DEVICE`. Consult {{< api SystemContext.run >}} for the current overloads.

The [changelog](https://github.com/larecs/larecs/blob/main/changelog.md) records release changes. The development reference does not imply that an unreleased declaration exists in a previously installed package.
