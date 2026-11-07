+++
type = "docs"
title = "Run threaded host kernels"
weight = 4
+++

Run independent particle rows in concurrent host chunks, then compare their
results with sequential execution. Start with
[systems and kernel access](../../systems_kernels). Threading is
[experimental](../../../reference/compatibility); it changes invocation
boundaries within one kernel call, while systems still run in registration
order.

## Keep inputs portable and work independent

The stage uses plain components and explicitly read-only time.

{{< example file="particles/threaded.mojo" region="model" >}}

The component fields contain only scalar values. Threaded eligibility checks
pointer-free trivial representation for accessed components; a device component
trait alone does not establish this. Unaccessed owning components can coexist
in the world.

The movement loop changes only its own row.

{{< example file="particles/threaded.mojo" region="kernel" >}}

`Resources().read[Time]()` shares one immutable time value with every chunk.
Ordinary mutable resources, including the `Resources[Time]()` read-write
default, are rejected even when a configuration uses sequential fallback.
[Adapter views](../portable_resources) can expose owning read inputs.

Opt in per invocation; configuring the world alone does not enable threading.

{{< example file="particles/threaded.mojo" region="system" >}}

`context.run[move, threaded=True]()` requires a nonraising thin kernel and HOST.
Lexical closures, explicit captures, and `threaded=True` with DEVICE fail at
compile time. {{< api EntitySelection.run >}} supports the same threaded engine
on exact selected ranges.

## Configure and check the result

This driver compares ordinary sequential execution, one-worker fallback, and a
four-task configuration, each from a fresh world.

{{< example file="particles/threaded.mojo" region="check" >}}

{{< api ThreadedExecutionConfig >}} sets a submitted-task budget, not reserved
cores or guaranteed OS thread overlap. `min_parallel_rows=0` disables the size
cutoff so the four-task case takes the chunk-dispatch path. All 4097 rows must
end at `(0.5, 1.0)`; the uneven count also exercises final short chunks.
This result check alone does not prove simultaneous worker overlap.

From the repository root, run:

```sh
pixi run mojo run -I src examples/particles/threaded.mojo
```

The PASS line confirms parity for all three call paths. Hardware concurrency
claims need separate worker-overlap evidence, such as the repository's
[threaded correctness tests](https://github.com/larecs/larecs/blob/main/test/threaded_execution_test.mojo).

## Respect chunk boundaries and lifetimes

Parallel dispatch splits each physical store or selected range independently.
Workers claim disjoint chunks dynamically; invocation order is unspecified.
Code outside the row loop runs once per chunk. A row's `idx` starts at zero in
each host context, including each chunk: do not index a shared global output
with it or treat it as an entity ID. `KernelContext.thread_count` remains one
inside a host chunk. Cross-chunk dependencies need a later `run` after the join.

Default settings are one worker, four target chunks per worker, and a 65,536
matched-row cutoff. One worker or fewer rows than the cutoff preserves
whole-range sequential calls, after all threaded eligibility checks. Empty
matches invoke no kernel. Worker/chunk counts must be positive, their product
representable, and the cutoff nonnegative.

Every explicitly threaded run acquires an extra structural lock, even for
fallback and an already locked selection. Lock exhaustion raises before work
starts. All fallible preparation precedes row writes, and all workers join
before the call returns. Fatal worker/runtime failures offer no rollback.

Keep one coordinating caller for the world. Structural locks and resource
leases are not mutexes for external aliases. Do not reenter execution, mutate
backing resources, or resize/relocate storage through escaped aliases while
workers run; copying, moving, replacing, or destroying an active world aborts.
Avoid mutable globals and callees with hidden unsafe mutation.

## Troubleshooting

| Failure or restriction | Fix |
| --- | --- |
| Plain-value check fails | Remove pointers/ownership from accessed components or ordinary read resources. `PlainValue` may declare opaque scalar-only `StaticTuple`/`InlineArray` fields; the author guarantees the entire representation is pointer-free and trivial. |
| Mutable ordinary resource rejected | Use explicit `read`, per-row component outputs, or an adapter declaring both mutation capabilities. A mutable adapter's concurrent-write contract remains your responsibility. |
| Small workload shows no improvement | Measure dispatch overhead and complete steps; adjust the cutoff only after profiling. |
| Structural lock exhaustion or locked world | Release unrelated queries/selections before running or maintaining storage. Empty/exhausted cursors can still own locks. |

See [the execution mapping](../device#select-the-target-in-the-system),
[shared-write alternatives](../shared_writes), and
[complete-step measurement](../../performance/measure).

{{< example file="particles/threaded.mojo" full=true >}}
