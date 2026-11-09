+++
type = "docs"
title = "Measure and tune a simulation"
weight = 1
+++

Check equal simulation work first, then measure complete steps and profile the
system that dominates them. Start with the [first simulation](../../../start/first_simulation).
Optional targets must pass [parity](../../execution/device) before timings
influence your choice. A smaller kernel time alone does not establish a faster
simulation.

## Establish a checked workload

The measurement stage uses plain particle values and fixed time.

{{< example file="particles/measurement.mojo" region="model" >}}

Keeping the same fields, precision, entity count, and step length makes target
comparisons meaningful. Validate every output needed by the application; a sum
alone can hide compensating per-entity errors.

Use the unchanged movement loop as the measured work.

{{< example file="particles/measurement.mojo" region="kernel" >}}

Each step reads velocity and time and updates both position coordinates.
Do not compare it with a variant that omits one coordinate, maintenance, or an
output that the real application needs.

## Profile the dominant system

The system adds an application-level Tracy zone around its complete `run` call.

{{< example file="particles/measurement.mojo" region="system" >}}

`particles.Move` includes binding and execution, not only row arithmetic. Larecs
also instruments internal work through Tracy. Compare system totals and call
counts before changing a loop; time saved in a minor system has limited effect
on a complete step. A host submission zone does not measure device kernel time
in isolation; use a backend profiler for device activity and transfer details.

## Measure complete updates separately from setup

The driver warms five steps, times twenty complete scheduler updates, and
validates all 4097 particle results outside the interval.

{{< example file="particles/measurement.mojo" region="measurement" >}}

The interval includes system dispatch and synchronous `run` costs. It excludes
compilation, world creation, initialization, warmup, finalization, validation,
and printing. Each particle must finish at `(6.25, 12.5)` after all 25 steps.
This small driver teaches timing boundaries; its single elapsed sample is not
a performance claim or a backend benchmark.

From the repository root, build once and run the binary for repeated samples:

```sh
pixi run mojo build -I src examples/particles/measurement.mojo -o /tmp/larecs-particles
/tmp/larecs-particles
```

The program prints a correctness PASS and a machine-local elapsed nanosecond
count. Record compilation separately. For a comparison, keep compiler version,
optimization flags, hardware, workload, and revision fixed, warm each variant,
alternate their order, and collect repeated paired samples without competing
jobs. Use optimized builds without tracing, debug info, or sanitizers for timing.
Follow the [benchmark methodology](../../benchmarks#benchmark-methodology) for
uncertainty, retained evidence, and regression checks.

## Separate arithmetic from boundary costs

| Measurement boundary | Include when comparing complete steps |
| --- | --- |
| Sequential host | Scheduler/system work, resource binding, store traversal, row processing, and required output handling. |
| Threaded host | The same work plus job preparation/dispatch/join; measure fallback and useful row-count thresholds. |
| Device | Packing, allocations when needed, input uploads, kernel launch/work, synchronization, downloads, and host scatter/publication. |
| Copy reuse | Validation and revisions, uploads that remain stale, mandatory output download, and invalidation caused by host edits or changing pack offsets. |
| Spatial locality | Input writes/dirty tracking, classification, sorting or partition transfer, location repair, and the passes that use the layout. |

Measure isolated kernels or maintenance passes to locate costs, then confirm the
full-step result. A device can save arithmetic time while losing to transfers;
a partitioned layout can improve one pass while increasing scan/binding costs.
Keep maintenance inside the timed step when the real application requires it.
Do not amortize a refresh across more steps than the correctness policy permits.
After every change, rerun output checks and compare complete-step samples.

## Capture a Tracy trace

Build a separate tracing binary inside Pixi's environment so the linker sees
the installed bindings and native library:

```sh
pixi run sh -c 'mojo build -I src -Xlinker -L"$CONDA_PREFIX/lib" -Xlinker -lmojotracy -DTRACY_ENABLED examples/particles/measurement.mojo -o /tmp/larecs-particles-tracy'
pixi run tracy-profiler
```

In Tracy, start discovery with **Connect**, then run
`/tmp/larecs-particles-tracy` in another terminal. Inspect `particles.complete_steps`,
`particles.Move`, and the internal zones for dominant work and repeated
preparation. The twenty measured steps may be short; use a longer representative
application run for profiling. Keep traced timings separate from optimized
untraced comparison samples. `pixi run profiling` traces the repository's
benchmark suite instead of this particle driver.

## Respect explicit SIMD limits

Columns store one component struct per row: `Position.x/y` are fields in a
`Position` column, not separate scalar columns. The public systems API exposes
row iteration and no explicit CPU SIMD-batch interface. `SIMD` fields and
compiler optimization do not create such an interface. Keep kernels on
`KernelContext` rather than reaching into archetype storage to force a batch
layout. Profile generated work before attributing a result to vectorization.

## Keep results with their conditions

Link measurements with their workload, hardware, compiler, revision, method,
uncertainty, and excluded costs. The
[host-dispatch investigation](https://github.com/larecs/larecs/blob/main/docs/design/research/host-thread-execution.md#measured-sequential-versus-threaded-calls),
[partition comparison](../../benchmarks#partitioned-storage-comparison), and
[resource execution report](../../benchmarks#resource-execution) provide scoped
evidence. They do not predict the best target or layout on another machine.

| Problem | Next check |
| --- | --- |
| Results differ | Compare independent initial worlds, access declarations, write-only initialization and shared writes before timing. Disable copy reuse while diagnosing stale data. |
| Device reports SKIP | Record host coverage separately; a hardware skip is not device execution. |
| Trace has no events | Rebuild the final application with `-DTRACY_ENABLED` and the library flags, and connect the profiler before the run. |
| Tiny or inconsistent timings | Increase representative work, warm up, use repeated paired samples, and separate setup/output from the interval. |

{{< example file="particles/measurement.mojo" full=true >}}
