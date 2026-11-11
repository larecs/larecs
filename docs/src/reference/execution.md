+++
type = "docs"
title = "Systems and execution"
weight = 3
+++

{{< api SystemContext.run >}} executes a kernel synchronously. For a complete thin kernel named `move`, use `context.run[move]()`. The [first simulation](../../start/first_simulation) defines its filter, components, resource, system and scheduler.

| Call form | Behavior |
| --- | --- |
| `context.run[move]()` | Default sequential host execution; one kernel call per matching nonempty physical store. |
| `context.run[move, threaded=True]()` | Experimental host chunks; eligibility checks still apply when configuration selects sequential execution. |
| `context.run[move, backend=ExecutionBackend.DEVICE]()` | Experimental accelerator execution with [no host fallback](../compatibility#no-device-fallback). |
| `context.run(kernel_func)` | Value-taking callable overload; lexical host captures are allowed, but the target must be sequential HOST. |
| `context.run[move](read_capture(x), mut_capture(y))` | Thin kernel with explicitly declared capture slots; bindings must follow the declared order. |

The generated `run` entry keeps overload anchors, access constraints, preparation errors, and both readable and exact compiler declarations. Read the [compatibility matrix](../compatibility) before changing targets.

| API | Contract |
| --- | --- |
| {{< api System >}} | Implement `update`; optionally implement `initialize` and `finalize`. |
| {{< api Scheduler >}} | Owns the world and registered systems; `run(steps)` initializes, updates for the requested steps, and finalizes. Individual lifecycle methods are also available. |
| {{< api KernelContext >}} | Borrows the current component and resource view; iterate it for row access. [Row indices are not entity IDs](../compatibility#row-indices-are-not-entity-ids). |
| {{< api ExecutionBackend >}} | Compile-time `HOST` or `DEVICE`; HOST is the default. |
| {{< api ThreadedExecutionConfig >}} | Worker/chunk settings and minimum row threshold; configuration alone does not enable threading. |

See [Execution](../../guide/execution) for complete particle programs per target. Kernels cannot perform arbitrary structural changes while execution holds structural locks. [Limits on every target](../compatibility#limits-on-every-target) covers device fallback, locks of empty queries, row indices, and locks versus mutexes.

## Threaded execution

`threaded=True` splits the rows of one call into kernel chunks; systems still run in registration order.

| Topic | Contract |
| --- | --- |
| Kernel and target | A nonraising thin kernel on `ExecutionBackend.HOST`. Lexical closures, explicit captures, and `threaded=True` with `DEVICE` fail at compile time. {{< api EntitySelection.run >}} supports the same engine on exact selected ranges. |
| Components | Accessed components must be pointer-free trivial plain values. Unaccessed owning components can coexist in the world. A `PlainValue` declaration admits opaque scalar-only `StaticTuple` or `InlineArray` fields; its author guarantees the whole representation is pointer-free and trivial. |
| Ordinary resources | Explicit `read` access and a pointer-free plain value. Writable access, including the `Resources[T]()` read-write default, is rejected even when the configuration selects sequential execution. |
| Adapted resources | Read views bind once on the coordinating caller and are shared until all workers join. Mutable views require `supports_concurrent_mutation`; the race-free write contract belongs to the adapter author. |
| Configuration | {{< api ThreadedExecutionConfig >}} defaults to one worker, four chunks per worker, and a 65,536 matched-row cutoff. `workers` is a submitted-task budget, not reserved cores or guaranteed OS-thread overlap. Worker and chunk counts must be positive and their product representable; the cutoff must be nonnegative, and zero disables it. |
| Sequential path | With one worker, or fewer matched rows than the cutoff, calls keep whole-range sequential granularity after all eligibility checks. Empty matches invoke no kernel. |
| Chunking | Each physical store or selected range splits independently. Workers claim chunks dynamically in unspecified order. Code outside the row loop runs once per chunk, `idx` starts at zero in each chunk, and `KernelContext.thread_count` is one. Dependencies between chunks need a later `run`. |
| Locks and preparation | Every threaded call acquires one extra structural lock, including the sequential path and calls on an already locked selection. Lock exhaustion raises before work starts. All fallible preparation precedes row writes. |
| Completion and failure | All workers join before `run` returns. Fatal worker or runtime failures offer no rollback. |
| Aliases | Keep one coordinating caller per world. Do not reenter execution, mutate backing resources, or resize or relocate storage through escaped aliases while workers run. Copying, moving, replacing, or destroying an active world aborts. Avoid mutable globals and callees with hidden unsafe mutation. |

## Device execution

`backend=ExecutionBackend.DEVICE` is a compile-time choice; a runtime choice needs an explicit branch calling each specialization. Device calls accept only thin kernels and visit each matched row once in one launch, using grid-stride iteration.

| Topic | Contract |
| --- | --- |
| Availability | Larecs checks device availability before resource preparation and has [no host fallback](../compatibility#no-device-fallback). |
| Components | Only accessed component types are checked; each must be `TrivialRegisterPassable`. |
| Ordinary resources | Recursively checked pointer-free trivial values with `read` or `read_write` access; `write` is rejected. `PlainValue` is a trusted declaration for opaque pointer-free trivial fields, not permission to transfer pointers. Mutable shared values require race-free writes. |
| Transfers | By default every call uploads all readable columns and resources. Larecs packs only matching ranges and scatters written columns back to their original host stores; rows outside a selection stay untouched. Resource views and capture values bind separately from columns. Allocation capacity can persist between calls. |
| Write-only components | `write[T]()` permits `set`, not `get`. Previous host bytes are not uploaded, so the kernel must set every visited row. |
| Empty match | Required resources and adapters still validate; no device allocation, upload, or launch occurs. Captures stay unchanged. Mutable adapters still prepare and finalize host output. A missing resource raises. |
| Completion | `run` returns after the launch, synchronization, and copy-back of written components, read-write resources, and mutable captures. Downloads land in owned staging buffers and are published, that is written to their host destinations, only after successful synchronization. |
| Failure | A transfer or synchronization failure discards unpublished staged outputs and drains the queue. If completion stays unknown, the world rejects further execution and must be replaced. Host effects are not rolled back. An adapter finalizer can raise after publication; published outputs remain. |

## Device-copy reuse

{{< api World.reuse_device_copies >}} lets a device call skip uploading a resource or component column whose device copy is current. Written outputs still download after every call.

| Data | Operations that advance its revision |
| --- | --- |
| Resource | `add`, `set`, `get` through mutable storage, and host, threaded, or device runs declaring writable access. Removal discards its records. |
| Component type in a physical store | Mutable storage or row access, setters, and kernels declaring writes, including on exact selected ranges. |
| All columns of affected stores | Structural changes, spatial row permutations, partition transfers, and store growth or replacement. |
| Escaped references or raw pointers | Not tracked. Call `world.resources.invalidate_device[T]()` for one resource or {{< api World.invalidate_device_copies >}} for all copies. |

- `read`, read-only queries, and `read` access in kernels preserve reusable copies. A mutable `get` advances the revision even when the caller only reads.
- A component copy is reused only for the same store incarnation, contiguous row range, packed offset, and revision. Alternating filters or selections can change packed offsets and cause uploads of unchanged values.
- Read-only adapted resources still validate and lease their sources; a current copy skips `prepare_device` and reuses its view. Mutable adapters always prepare. Explicit captures upload on every call.
- Failed invocations invalidate the copies they touched. A world copy starts with independent host owners and empty device records. Disabling reuse discards records; completion stays synchronous.
- Invalidation does not permit mutation during a live invocation and does not make an invalid reference safe.
