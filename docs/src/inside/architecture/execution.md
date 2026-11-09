+++
type = "docs"
title = "Host, threaded, and device work mapping"
weight = 4
+++

{{< api SystemContext.run run >}} selects a compile-time
{{< api ExecutionBackend >}}, defaulting to `HOST`. A thin kernel can use
either target. Value-taking callables use the sequential host; threaded host
execution requires an eligible nonraising thin kernel. `DEVICE` validates
support and a working context even when no rows match, and never falls back.

The mapping diagram follows two physical ranges through all three executors.

![Sequential host calls process two ranges, threaded tasks claim disjoint local chunks, and four illustrative device threads visit seven packed rows by grid stride.](/images/execution-mapping.svg)

*Ranges remain separate on the host; device work uses a packed row domain.*

Sequential host execution binds resources once and traverses nonempty matching
physical stores. Each context contains pointers to its first row and a local
length. Selected runs use the saved exact ranges. The iterator begins at zero
and increments by one. Empty matches call no kernel, while resource validation
and mutable adapter lifecycle work can still occur.

## Preparing and draining threaded jobs

`_run_threaded` validates eligibility independently of fallback, retains active
execution and structural guards, binds resources, and checks all ranges and
integer limits. Selected ranges are checked for overlap on a sorted copy;
the saved order remains available for fallback.

For enough rows and more than one configured worker, the target job count is
`workers * chunks_per_worker`; chunk size is the ceiling of total matched rows
divided by that target. Each range splits independently, so the actual job count
can exceed the target. Every chunk gets offset column pointers and local indices.
All fallible preparation finishes before kernels write rows.

Workers use an atomic `UInt32` cursor to claim prepared contexts dynamically.
There is no fixed store-to-thread assignment. `parallelize` schedules at most
the configured worker count and joins before finalization and release. Below
the row cutoff, or with one worker, calls retain whole-range sequential
granularity; eligibility checks still apply. Row ownership prevents overlap
between chunks, but shared mutable adapted data still requires its adapter's
concurrent-mutation contract.

## Packed device iteration

Device execution allocates or grows one buffer per accessed component type,
packs matching spans, prepares resources/captures, and launches the kernel.
`EntityAccessorIterator` starts each GPU thread at `global_idx.x` and advances
by `context.thread_count`. A thread stops when its offset reaches the packed
length. That grid-stride rule covers every row once, including when the launch
has fewer threads than rows.

The current launch uses 256 threads per block. `gpu_grid_dim` starts with
`ceil(length / 256)` and caps blocks with a thread-based device residency bound
when device attributes are available. Missing attributes disable the cap.
This bound ignores register and shared-memory usage; it is not an occupancy
guarantee. The iterator performs no transfer or synchronization itself.
Written spans return through [staged transfers](../transfers) before `run`
returns.

The diagram adapts the thesis's host, threaded-host, and grid-stride figures;
four device threads illustrate the indexing rule rather than the actual block
size. Public restrictions and call forms are in the
[execution reference](../../../reference/execution).

Implementation: {{< source "system.mojo" >}},
{{< source "execution.mojo" >}}, {{< source "iteration.mojo" >}},
{{< source "gpu_launch.mojo" >}}.
Evidence: {{< repo "test/grid_stride_iterator_test.mojo" >}},
{{< repo "test/threaded_execution_test.mojo" >}},
{{< repo "test/gpu_launch_cap_test.mojo" >}},
{{< repo "test/check_execution_backend_contracts.py" >}}.
