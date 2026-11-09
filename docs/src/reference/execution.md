---
title: Systems and execution
type: docs
---

{{< api SystemContext.run >}} executes a kernel synchronously. For a complete thin kernel named `move`, use `context.run[move]()`. The [first simulation](../../start/first_simulation) defines its filter, components, resource, system and scheduler.

| Call form | Behavior |
| --- | --- |
| `context.run[move]()` | Default sequential host execution; one kernel call per matching nonempty physical store. |
| `context.run[move, threaded=True]()` | Experimental host chunks; eligibility checks still apply when configuration selects sequential execution. |
| `context.run[move, backend=ExecutionBackend.DEVICE]()` | Experimental accelerator execution. No host fallback; missing hardware raises even for empty matches. |
| `context.run(kernel_func)` | Value-taking callable overload; lexical host captures are allowed, but the target must be sequential HOST. |
| `context.run[move](read_capture(x), mut_capture(y))` | Thin kernel with explicitly declared capture slots; bindings must follow the declared order. |

The generated `run` entry keeps overload anchors, access constraints, preparation errors, and both readable and exact compiler declarations. Read the [compatibility matrix](../compatibility) before changing targets.

| API | Contract |
| --- | --- |
| {{< api System >}} | Implement `update`; optionally implement `initialize` and `finalize`. |
| {{< api Scheduler >}} | Owns the world and registered systems; `run(steps)` initializes, updates for the requested steps, and finalizes. Individual lifecycle methods are also available. |
| {{< api KernelContext >}} | Borrows the current component/resource view; iterate it for row access. Row indices are local to each context. |
| {{< api ExecutionBackend >}} | Compile-time `HOST` or `DEVICE`; HOST is the default. |
| {{< api ThreadedExecutionConfig >}} | Worker/chunk settings and minimum row threshold; configuration alone does not enable threading. |

See [Execution](../../guide/execution) for independent particle stages and target restrictions. Kernels cannot perform arbitrary structural changes while execution holds structural locks.
