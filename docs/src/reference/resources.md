+++
type = "docs"
title = "Resources and captures"
weight = 4
+++

{{< api ResourceStorage >}} stores one shared value per resource type. Add values during setup with `world.resources.add(Time(0.25))`. Declare a kernel's access with {{< api Resources >}}, for example `Resources().read[Time]()`; undeclared access fails at compile time.

| API | Contract |
| --- | --- |
| {{< api ResourceStorage.add >}}, {{< api ResourceStorage.set >}}, {{< api ResourceStorage.remove >}} | Insert, replace or remove a value; generated entries state presence requirements and failure behavior. |
| {{< api Resources >}} | {{< api Resources.read read >}} grants immutable access, {{< api Resources.write write >}} fresh output access, and {{< api Resources.read_write read_write >}} mutable access preserving existing contents. |
| {{< api DevicePassableResource >}} | Owning resource sources opt into adapted kernel views. The selected view depends on declared access and execution target. |
| {{< api ResourceAdapter >}}, {{< api ResourceAccess >}} | Adapter protocol and `READ`, `WRITE`, `READ_WRITE` modes; fresh WRITE does not preserve prior contents. |
| {{< api BufferResource >}}, {{< api ReadBuffer >}} | Buffer source and immutable view for adapter-backed resources. |
| {{< api ResourceDeviceCache >}} | Allocation cache used by the adapter protocol; it does not replace a source's ownership or revision contract. |
| {{< api Captures >}}, {{< api ReadCapture >}}, {{< api MutCapture >}} | Ordered declarations for explicitly bound host-local values, independent of resource types. |
| {{< api read_capture >}}, {{< api mut_capture >}} | Bind borrowed values in declaration order; keep their owners alive through the synchronous call. |

Ordinary resources can own heap data on sequential host execution. Device plain resources require a recursively checked pointer-free representation; an owning resource instead needs an adapter. These rules differ from the component transfer check; see [compatibility](../compatibility).

The [portable resource guide](../../guide/execution/portable_resources) and [capture guide](../../guide/execution/captures) provide independent particle programs. [Reuse unchanged device copies](../../guide/execution/copy_reuse) covers revisions and escaped-reference invalidation.
