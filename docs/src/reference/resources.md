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
| {{< api DevicePassableResource >}} | Owning resource sources opt into adapter-built kernel views and become portable resources. The selected view depends on declared access and execution target. |
| {{< api ResourceAdapter >}}, {{< api ResourceAccess >}} | Adapter protocol and `READ`, `WRITE`, `READ_WRITE` modes; fresh WRITE does not preserve prior contents. |
| {{< api BufferResource >}}, {{< api ReadBuffer >}} | Buffer source and immutable view for portable resources. |
| {{< api ResourceDeviceCache >}} | Allocation cache used by the adapter protocol; it does not replace a source's ownership or revision contract. |
| {{< api Captures >}}, {{< api ReadCapture >}}, {{< api MutCapture >}} | Ordered declarations for explicitly bound host-local values, independent of resource types. |
| {{< api read_capture >}}, {{< api mut_capture >}} | Bind borrowed values in declaration order; keep their owners alive through the synchronous call. |

Ordinary resources can own heap data on sequential host execution. Device plain resources require a recursively checked pointer-free representation; an owning resource instead needs an adapter. These rules differ from the component transfer check; see [compatibility](../compatibility).

The [portable resource guide](../../guide/execution/portable_resources) and [capture guide](../../guide/execution/captures) provide independent particle programs. [Reuse unchanged device copies](../../guide/execution/copy_reuse) covers revisions and escaped-reference invalidation.

## Explicit captures

| Topic | Contract |
| --- | --- |
| Slots | `Captures` lists slots in order. Bindings must match the slot count, types, and mutability in that order; slots may share a type. `context.captures.get[i]()` is immutable for a `ReadCapture` slot. |
| Mutable slots | One `MutCapture` value is shared by every invocation and every device thread, not private per row. Mutable access supplies no synchronization; use one proven writer or per-row output. |
| Host binding | Host execution borrows the original values until `run` returns. |
| Device binding | Device execution uploads every binding on each call and copies mutable slots back before `run` returns. Device captures copy trivial bytes and must own no heap data; there is no `DevicePassableResource` conversion. |
| Empty match | Captures stay unchanged. |
| Targets | Sequential host and device accept explicit captures; threaded execution rejects them at compile time. Lexical closures require sequential host execution. |
| Lifetime | References and pointers from capture slots or lexical borrows must not escape the invocation. Do not capture an alias that structurally changes the world while rows are borrowed. |

## Adapter contracts

A {{< api DevicePassableResource >}} source names a stateless {{< api ResourceAdapter >}}. Adapters register automatically when the source is added or inserted with `set`; there is no adapter factory. Kernels request the source type and receive its view; lookup uses source identity, so two sources may share a view type.

| Hook or topic | Contract |
| --- | --- |
| `validate` | Runs before binding either target on every call, including empty matches and current reused copies. |
| `bind_host` | Returns a view into the retained source, never into a temporary. Its untracked origin states the lifetime obligation; it does not transfer ownership. |
| `prepare_device` | Uploads through {{< api ResourceDeviceCache >}}. `cache.upload` snapshots supported pointer-free trivial samples in owned staging buffers before enqueueing. Use distinct nonnegative stable slots per array; Larecs reserves slot `-1` for the descriptor. Do not enqueue copies from external host pointers or temporary allocations. |
| Cache | Belongs to the source type, world, and device context. It retains allocation capacity; by default preparation still uploads current data on each call. |
| Leases | Larecs validates sources, leases them, and retains views until synchronous completion, including the join of threaded workers. Reentrant lookup, replacement, or removal of a leased source raises. Copying, moving, or destroying leased storage through an escaped alias aborts. |
| View lifetime | Views, their pointers, and references obtained from them must not escape the invocation. The pointer in a view is target-local. |
| Read views | Every read view and all reachable storage must support concurrent reads without hidden mutation. An immutable pointer field alone does not establish this. Escaped aliases must not mutate, resize, relocate, or free the backing collection while a call uses it. Threaded calls bind read adapters once on the coordinating caller. |

## Mutable adapters

Mutable portable resources are experimental.

- `supports_mutation` permits writable views on sequential host calls; `supports_concurrent_mutation` additionally permits them on threaded and device calls. Both are author guarantees: a source lease does not prevent races among the workers of one invocation, because [leases are not mutexes](../compatibility#structural-locks-are-not-mutexes).
- `write` selects fresh, adapter-initialized output; `read_write` preserves existing contents. The descriptor itself stays immutable; its methods control writes to backing storage.
- Preparation and finalization run once per invocation, even for empty matches. Mutable adapters prepare on every call, even with device-copy reuse.
- `Resources[T]()` without a mode means read-write and fails to compile for an adapter without `supports_mutation`.

The [checked scatter example](https://github.com/larecs/larecs/blob/main/examples/scatter_resource.mojo) shows the hooks and an atomic slot reservation.
