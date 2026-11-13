+++
type = "docs"
title = "Run threaded host kernels"
weight = 1
+++

Split one particle movement call into chunks that run concurrently on host
worker threads. Use this when a single kernel call covers many independent rows
and [profiling](../../performance) shows that the call dominates a step. Only
the rows of one call are split; systems still run one after another in
registration order. Threaded execution is
[experimental](../../../reference/compatibility).

Start with [Update entities with systems and kernels](../../systems_kernels).

## Move particles in threaded chunks

The stage uses the [portable particle model](../#the-portable-particle-model)
and the movement kernel from the first simulation.

{{< example file="particles/threaded.mojo" region="model" >}}

{{< example file="particles/threaded.mojo" region="kernel" >}}

`move` is a *thin kernel*: a named `def` function that `run` receives as a
compile-time parameter, as in `context.run[move]()`. It captures no local
variables and declares no capture slots; threaded execution requires both. Each
row writes only its own `Position`, so no two chunks write the same data.
`Resources().read[Time]()` declares `Time` read-only, so all chunks share one
immutable value.

Opt in for one call with `threaded=True`:

{{< example file="particles/threaded.mojo" region="system" >}}

Then give the world more than one worker:

{{< example file="particles/threaded.mojo" region="check" >}}

{{< api ThreadedExecutionConfig >}} sets the number of tasks Larecs submits per
call, not reserved cores. `chunks_per_worker=2` targets two chunks per worker,
and `min_parallel_rows=0` removes the row cutoff, so the 4097 particles split
into chunks. The driver runs the same two steps three times, each in a fresh
world: sequentially, threaded with one worker, and threaded with four workers.

From the repository root, run:

```sh
pixi run mojo run -I src examples/particles/threaded.mojo
```

The program prints a PASS line when all three runs move every particle to
`(0.5, 1.0)`.

## How Larecs splits the rows

Larecs splits each matching physical store into *kernel chunks*: contiguous
row ranges, each passed to one kernel invocation. Workers claim chunks in an
unspecified order, and `run` returns only after every chunk has finished. This
changes what code outside the row loop sees:

- Code before or after the `for` loop runs once per chunk, not once per store.
- A row's `idx` restarts at zero in each chunk; [row indices are not entity
  IDs](../../../reference/compatibility#row-indices-are-not-entity-ids).
- Work that reads rows of other chunks needs a later `run`, after this call
  returns.

[Work
mapping](../../../inside/architecture/execution#preparing-and-draining-threaded-jobs)
explains how Larecs sizes chunks.

## Variations

### Keep small calls sequential

The default configuration has one worker, four chunks per worker, and a cutoff
of 65,536 matched rows. With one worker, or with fewer matched rows than
`min_parallel_rows`, a `threaded=True` call runs sequentially, once per physical
store or selected range. Keep `threaded=True` in the system and set the worker
budget per world; the compile-time eligibility checks apply either way.

### Run threaded on a selection

{{< api EntitySelection.run >}} accepts the same `threaded=True` parameter and
splits only the selection's rows.

### Read an owning collection

Ordinary resources in a threaded call must be read-only values without
pointers or owned memory. To read a list or buffer, wrap it in a
[portable resource](../portable_resources).

## Failures and limits

| Failure | Cause and fix |
| --- | --- |
| `Threaded components require pointer-free trivial plain values` | An accessed component holds a pointer or owns memory, such as a `List`. Remove it from the filter, or keep that data in a portable resource. |
| `Threaded resources require pointer-free plain values or DevicePassableResource adapters` | A `read` resource owns memory or holds a pointer. Use a [portable resource](../portable_resources). |
| `Threaded resources require explicit read access` | The kernel declares an ordinary resource as writable, including through the `Resources[Time]()` read-write default. Declare it with `read`, or write per-row output as in [Coordinate shared writes](../shared_writes). |
| Compile error for a lexical closure, captures, or `DEVICE` | Threaded execution requires a thin kernel without capture slots on `ExecutionBackend.HOST`. |
| `ThreadedExecutionConfig` raises | `workers` and `chunks_per_worker` must be positive, their product must fit in an `Int`, and `min_parallel_rows` must not be negative. |
| Structural lock exhaustion | Each threaded call adds one structural lock to those already held, even when it runs sequentially. Live queries and selections, [even empty ones](../../../reference/compatibility#empty-queries-and-selections-hold-structural-locks), hold the others; end those you no longer need. |
| No speedup | Dispatch costs time; [measure complete steps](../../performance/measure) before you change the cutoff. |

Chunks are independent only in the rows they visit. [Structural locks are not
mutexes](../../../reference/compatibility#structural-locks-are-not-mutexes):
shared state still needs a race-free write strategy. The
[threaded execution reference](../../../reference/execution#threaded-execution)
lists the remaining lock, alias, and failure rules.

## Complete program

{{< example file="particles/threaded.mojo" full=true >}}

## Next steps

- [Execute on a device](../device) runs the same kernel on an accelerator.
- [Coordinate shared writes](../shared_writes) combines results from many
  chunks.
- [Measure complete simulation steps](../../performance/measure) before you
  keep threading.
