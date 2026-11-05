# Host thread execution investigation

This is a feasibility investigation and recommendation, not an accepted design
or an implemented execution engine. Inspected at `34e86b3` with Mojo 1.0.0
(`ed45d567`) and MAX 26.5.0. The proposed starting point is a configurable,
fixed worker count, with each kernel/archetype pair forming a job that any
available worker can claim.

## Findings

The existing kernel interface is suitable for this model. The host branches of
`SystemContext.run` and `EntitySelection.run` already call a kernel on bounded
physical-store ranges. `_host_kernel_context` offsets column pointers to the
range start and supplies invocation-wide resource/capture bindings. Each worker
can run the existing kernel body unchanged, iterating sequentially inside its
own range. `KernelContext.thread_count` stays **1 for each host job**; it is not
the engine's pool size. The host iterator does not use it to partition rows.

There is currently no interchangeable execution-engine abstraction:
`on_device` selects inline host/device branches in `system.mojo`.
`Scheduler.update` runs systems sequentially. An initial threaded engine can
preserve that order and make every `run` a synchronous completion boundary.
Parallel systems and asynchronous kernel calls would require additional design.

The main difficulty is proving safe concurrent access, not launching tasks.

## Runtime support and the fixed-thread distinction

The installed project's synchronization tests already use
`max.algorithm.parallelize(worker, 8, 4)`. Inspecting the matching
[MAX 26.5 CPU implementation](https://github.com/modular/modular/blob/max/v26.5.0/max/mojo/max/algorithm/backend/cpu/parallelize.mojo)
shows that `parallelize(function, job_count, worker_count)` statically divides
consecutive job indices among worker tasks. This alone does not give dynamic
pickup of individual archetypes when their costs differ.

A small implementation can instead launch `worker_count` tasks, each repeatedly
claiming the next prepared job through an atomic fetch-add. The job table is
published before launch and remains immutable through completion. A relaxed
atomic is sufficient for allocating unique indices; launch and join must supply
the publication/completion boundary. A bounded cursor must account for terminal
claims by every worker and reject job counts that could overflow its type.

The runtime already owns a pool. The matching
[Mojo runtime source](https://github.com/modular/modular/blob/max/v26.5.0/mojo/stdlib/std/runtime/asyncrt.mojo)
documents process-lifetime runtime initialization and a query for available
worker threads. MAX's synchronous dispatcher enqueues a CPU range and
synchronizes it. **Requesting N worker tasks does not establish ownership of
exactly N persistent OS threads**, isolate the pool from other MAX work, or
guarantee N simultaneous workers. Small launches may execute on fewer threads.

If the requirement is a fixed concurrency budget, prototype on this runtime
first and clamp active tasks to the job count. If it requires a dedicated pool
with exactly N background threads, first verify a supported configurable CPU
runtime/context API on the locked release. Otherwise a native thread-pool
adapter would need construction, parking/wakeup, shutdown/join, callback ABI,
and runtime initialization on foreign threads. Do not promise that guarantee
based on `parallelize`'s worker argument. Also define whether the calling thread
participates in N; a dedicated N-worker proposal should initially keep the caller
as coordinator, outside that count. Validate configuration before starting work,
keep it fixed for the engine lifetime, and reject zero/negative counts.

## Proposed execution boundary

1. On the calling thread, validate the kernel and bindings and prevent structural
   mutations until every job completes. Ordinary execution needs its own guard;
   selections already retain one. `LockManager` prevents ECS structural changes
   but is not a mutex and must not be mutated by workers.
2. Bind resources/captures once, retain all source leases and adapter descriptor
   owners, discover matching nonempty ranges, and prepare contexts. Perform
   spatial write invalidation here, before launch, including failure paths.
   Workers must not append to dirty queues or touch storage directories.
3. Publish prepared contexts and launch the fixed set of worker tasks. Each task
   claims a job, invokes the specialized thin kernel, and repeats until drained.
   Workers receive contexts, not mutable `World` or `HostStorage` access.
4. Join all tasks before destroying contexts, releasing bindings/leases or the
   structural guard, propagating an error, or running the next kernel/system.

Avoid one thread per archetype and avoid per-entity locks. A flat job array plus
an atomic cursor is enough for this synchronous model; a general dependency
graph or work-stealing deque is not initially necessary.

With spatial partitions, one logical component archetype has several physical
stores. The natural initial job is **one matching physical store**, including
staging stores, rather than one logical transition-graph node. Selected execution
must intersect the filter with exact saved ranges and never process intervening
unselected rows. Initially use one job per nonempty saved range, proving
nonoverlap, or group a store's disjoint ranges under one job. Specify which
choice determines kernel invocation counts; setup/side effects outside the row
loop can observe that choice.

## Safety and compatibility work

| Area | Required treatment |
| --- | --- |
| Component columns | Validate disjoint job row sets; freeze storage and locations until join. Disjoint rows do not prove disjoint pointees inside arbitrary pointer-bearing components. |
| Shared resources | Ordinary `Resources[T]()` defaults to mutable access. Reject mutable/write-only resources in the initial threaded path; reads need a contract covering reachable storage and interior mutation. Resource leases preserve lifetime, not mutual exclusion between jobs. |
| Explicit captures | Reject `MutCapture` initially. Read bindings need the same reachable-storage contract and alias checks against writable columns or other writable memory. Copying pointer arrays does not isolate payloads. |
| Lexical closures/global state | Restrict initial support to thin kernels with explicit checked bindings. A thin function can still access unsafe globals or call non-thread-safe libraries; document the boundary of enforcement. Do not blindly parallelize the existing closure overload. |
| Synchronization | Decision 0016 has standalone tested primitives, but dedicated resource/capture bindings and alias rejection remain unfinished. Complete those before enabling ordinary shared mutable bindings. Proposed deferred access in 0017 is not a prerequisite for component-only jobs. |
| Reentrancy | Keep the world confined to the coordinating caller; reject nested submissions/reentrant world execution initially. A structural guard alone does not prevent component aliasing or serialize external callers. |
| Errors | Prepare fallible contexts before launch. Current thin kernel signatures are nonraising, while host closures can raise. MAX `sync_parallelize` aborts on caught errors; it does not transport them to the caller. Any future raising worker adapter must catch locally, retain per-job error state, join all work, and then raise. Define partial writes and cancellation; never release borrowed storage while work remains active. |
| Ownership | `World` and `Scheduler` are copyable. A persistent engine cannot gain accidental pool duplication or shutdown through synthesized copies. Choose explicit shared pool ownership or a fresh idle pool on copy; prohibit copying/moving an active engine and retain stable job storage through join. |

Start with scalar/value components and no resources/captures, then permit audited
read-only bindings. Thread safety of arbitrary component/resource types cannot
be inferred from `Copyable`, trivial representation, or a read-only descriptor.
Define a checked capability or documented unsafe extension for representations
with shared reachable state before advertising general host-kernel compatibility.

Keep sequential host execution as the default. Add an explicit engine selection
and runtime worker configuration, distinguishing sequential host, threaded host,
and device execution; reject conflicting selection with `on_device`. Exact API
spelling needs a compile probe because `run` infers kernel/filter specializations
and scheduler system callbacks erase context types. Prefer runtime configuration
reachable through `World`/`SystemContext` so worker count does not parameterize
every user kernel. Support direct contexts and selections as well as scheduling.

ECS-09 currently states that host iteration is sequential. Clarify sequential
iteration *within each job* versus concurrent jobs in a proposed numbered
decision before implementation is accepted. Update affected requirements and
guides only on acceptance; retain current behavior until then.

## Validation and performance scope

The accompanying [manual probe](host-thread-dispatch-probe.mojo) prepares actual
Larecs contexts on the caller and reuses one component-only kernel on dynamically
claimed jobs. Build once and run:

```sh
pixi run mojo build -I src docs/design/research/host-thread-dispatch-probe.mojo -o /tmp/larecs-thread-probe
/tmp/larecs-thread-probe
```

On Linux x86-64, AMD Ryzen 7 PRO 5850U (8 cores/16 hardware threads), the probe
passed at 1, 2, and 4 worker tasks: four stores, 256 rows each, 100 invocations,
with every resulting row checked. Four distinct pthread IDs were observed in
the initial four-task experiment. IDs are diagnostic, not assertions of sustained
concurrency, dedicated ownership, or thread-count enforcement. That probe is
dispatch feasibility evidence only. The measurements below add synthetic timing
evidence; macOS, selections, partitions, binding safety, and failure recovery
remain unvalidated.

Production coverage should verify exact once-only row processing, empty matches,
more jobs than workers and vice versa, skewed store sizes, exclusions, exact
disjoint selections, partition/staging stores, successive kernel visibility,
spatial invalidation, rejected unsafe bindings, structural mutation rejection,
nested execution, pool shutdown/copy ownership, and any supported error paths.
Use publication and contention checks to exercise actual concurrency; success
on a serial schedule is insufficient evidence for worker safety.

Measure sequential versus threaded execution with identical entities and row
work: 1/2/4 workers; one/few/many stores; balanced/skewed stores; small/large row
counts; cheap bandwidth-bound and heavier compute kernels. Include job discovery,
validation, invalidation, launch and join in complete-call timing, and report
pool initialization and compilation separately. Preserve the unchanged sequential
control. Benchmark queue contention and false sharing before adopting thresholds
or queue optimizations, keeping the normal PR suite within its time budget.

One job per store limits useful concurrency to the matching store count, and
the longest job bounds completion time. A world dominated by one archetype will
not scale under that initial policy. The chunk experiment below addresses this
without changing entity iteration, but changes observable kernel call counts
and still needs a production contract.

## Measured sequential versus threaded calls

The initial version of the manual [timing driver](host-thread-benchmark.mojo) compared the existing
`SystemContext.run` sequential path with the experimental atomic-cursor
dispatcher. Both invoke the same non-inlined kernel specialization on identical
initial entities and store layouts, in separate worlds. All component values
start at one. Each completed world is checked against the exact expected value
accounting for every warmup, calibration, and measured call, with all checks
outside the timed region. The increment is the original probe's arithmetic workload, using
UInt32 instead of Int32; the heavier case performs 32 dependent xor/shift/multiply/
add rounds per row using wrapping UInt32 arithmetic.

Measured on the Linux/Ryzen 7 PRO 5850U described above, Linux
`7.2.5-3-omarchy`, Mojo 1.0.0 (`ed45d567`), MAX 26.5.0. The driver was built
once with normal optimization, without debug info, tracing, or sanitizers;
the successful build took 12.04 seconds in the already installed environment.
This is not a cold-cache compilation measurement. Three consecutive binary
executions took 4.84, 4.87, and 4.87 seconds; all completed successfully.
No benchmark jobs or builds were launched concurrently with sampling.

Each case warms both paths with two calls. Sequential calibration doubles from
one to at most 4,096 calls, stopping when a batch reaches 10 ms; the same batch
count is then used for both paths in five pairs, alternating execution order.
The three runs yield 15 pairs per case/worker count. Timing includes each complete
call: sequential context setup and dispatch, or threaded structural guard,
binding preparation, store discovery, context allocation, atomic cursor setup,
worker dispatch, row work, synchronization, and cleanup. World creation,
validation, runtime initialization/warmup, compilation, and pthread diagnostics
are excluded. There is no spatial policy or nonempty resource/capture binding;
all stores match the filter. This is a restricted dispatch prototype, not a
measurement of the unresolved production safety machinery.

Times below are median microseconds per call from the four-worker comparison.
Speedups are medians of the paired sequential/threaded ratios for each worker
count, so they need not equal a ratio of the displayed median times. Above 1×
is faster; below 1× is slower. Four-store cases are balanced.

| Total rows | Stores | Work per row | Sequential µs | Four-worker µs | One-task speedup | Two-task speedup | Four-task speedup |
| ---: | ---: | --- | ---: | ---: | ---: | ---: | ---: |
| 1,024 | 4 | increment | 0.455 | 8.534 | 0.98× | 0.06× | 0.05× |
| 1,024 | 4 | 32 rounds | 28.154 | 16.234 | 1.00× | 1.22× | 1.72× |
| 65,536 | 4 | increment | 18.611 | 13.763 | 1.00× | 1.06× | 1.36× |
| 65,536 | 4 | 32 rounds | 1,796.710 | 545.911 | 1.00× | 1.85× | 3.35× |
| 1,048,576 | 4 | increment | 300.962 | 95.943 | 1.00× | 1.74× | 3.15× |
| 1,048,576 | 4 | 32 rounds | 28,357.692 | 7,662.863 | 1.00× | 1.89× | 3.71× |
| 262,144 | 1 | 32 rounds | 7,200.936 | 7,263.269 | 1.00× | 0.99× | 0.99× |

Four-worker per-run median paired speedups were 2.88–3.20× for the million-row
increment and 3.71–3.76× for the million-row heavier kernel. The 65,536-row
heavier case varied from 3.02–3.63×, illustrating local timing variation.
The original tiny increment loses roughly 19× to dispatch overhead, while the
one-store control has essentially no speedup. These results support an opt-in
engine and a future measured sequential cutoff; they do not establish a portable
cutoff, application speedup, scaling beyond four jobs, or performance under skew,
contention, spatial maintenance, or realistic shared bindings. CPU affinity and
frequency were not pinned, and this is one developer machine.

Reproduce using one optimized binary, without concurrent compilation or timing:

```sh
pixi run mojo build -I src docs/design/research/host-thread-benchmark.mojo -o /tmp/larecs-thread-benchmark
/tmp/larecs-thread-benchmark
/tmp/larecs-thread-benchmark
/tmp/larecs-thread-benchmark
```

The original `PAIR` lines report rows per store, store count, arithmetic rounds,
worker task count, pair index, calls per batch, sequential ns/call, and threaded
ns/call. The extended driver described below additionally prefixes those fields
with a chunk-mode flag.
Raw output from this investigation is retained locally in the ignored
`output/host-thread-investigation/run-{1,2,3}.txt` files. This driver remains a
manual experiment and is not added to the normal PR performance gate.

## Contiguous chunks using EntityAccessorIterator

The extended probe splits a physical store into nonoverlapping contiguous ranges
and prepares each job with `_host_kernel_context(store, first_row, row_count, ...)`.
That helper offsets all component pointers to the chunk's start. The existing
`EntityAccessorIterator` then visits local rows `0 .. row_count` with stride one;
neither the iterator nor the user kernel needs modification. The structural guard
and invocation-wide binding owners remain alive until every chunk completes.
This is an experimental dispatch policy, not an accepted execution contract.

The correctness probe now also processes four 259-row stores with a maximum of
63 rows per job: 20 jobs in total, with a seven-row final chunk in each store.
Runs with 1/2/4 worker tasks passed 100 invocations, checking each row's distinct
initial index plus 100. A four-worker case with one row per store also passed.
Context lengths, host thread count one, and total job counts are checked outside
execution. These checks exercise nonzero pointer offsets, exact chunk bounds,
short tails, and small stores without changing the iterator implementation.

The timing driver retains the whole-store mode and adds chunk mode. In chunk
mode, each call sums the row counts and chooses
`max(1, ceil(total_rows / (4 * worker_count)))` rows per chunk. Each store is
split independently, preserving its boundaries; the last chunk may be shorter.
This targets four jobs per worker across the world (16 jobs with four workers
in the measured cases). It is an experimental policy, not a tuned universal
chunk size or a strict job-count cap for arbitrary store distributions.

Both modes are measured in the same optimized binary against unchanged ordinary
sequential execution. Chunk-size calculation, the extra discovery pass, context
construction/allocation, atomic job claiming, launch/join, and cleanup are all
included in complete-call timing. The existing warmup, bounded calibration,
alternating sequential/threaded pair order, and outside-timer row validation are
unchanged. There are now nine scenarios for each of two policies and three worker
counts, giving 270 pairs per binary execution and 810 pairs across three runs.
Each policy has its own paired sequential measurements; whole-store/chunked
times below are not directly paired with each other.

Same machine, OS, compiler, and MAX version as above. The final extended driver
built in 13.20 seconds in the installed environment. Three consecutive executions
took 13.82, 13.80, and 13.90 seconds, all successful. No timing jobs or builds
were launched concurrently. The 1/2/4-task matrix and all resulting rows passed.
Times are median microseconds per call with four worker tasks; the sequential
column comes from the chunk-mode pairs. Speedup is the median paired
sequential/chunked ratio, not a ratio of displayed medians.

| Total rows | Stores | Work per row | Sequential µs | Whole-store µs | Chunked µs | Chunk speedup |
| ---: | ---: | --- | ---: | ---: | ---: | ---: |
| 1,024 | 4 | increment | 0.459 | 8.639 | 9.438 | 0.05× |
| 1,024 | 4 | 32 rounds | 28.630 | 16.701 | 17.399 | 1.66× |
| 65,536 | 4 | increment | 18.622 | 14.109 | 13.941 | 1.34× |
| 65,536 | 4 | 32 rounds | 1,810.483 | 534.766 | 504.741 | 3.58× |
| 1,048,576 | 4 | increment | 294.663 | 97.464 | 100.256 | 3.02× |
| 1,048,576 | 4 | 32 rounds | 28,667.031 | 7,654.842 | 7,648.439 | 3.75× |
| 262,144 | 1 | increment | 73.859 | 91.114 | 31.916 | 2.32× |
| 262,144 | 1 | 32 rounds | 7,141.984 | 7,454.078 | 2,017.511 | 3.54× |
| 1,048,576 | 1 | 32 rounds | 28,676.760 | 28,712.667 | 7,655.763 | 3.74× |

For the single-store million-row heavier kernel, chunked speedup was 1.00×,
1.95×, and 3.74× at 1/2/4 worker tasks. Four-worker per-run median paired
speedups were 3.52–3.75×. Chunking removes the single-store parallelism limit in
this workload. Four balanced stores already give enough whole-store jobs to keep
four workers busy; their large heavier workload has similar timings under both
policies. Small row updates still lose to dispatch overhead, and chunking adds
job preparation/claiming costs. These measurements do not establish that chunking
is always faster than whole-store dispatch or determine a production cutoff.

Build and repeat using the commands above; the extended `PAIR` format is:
chunk flag (`0` whole-store, `1` chunks), rows per store, store count, arithmetic
rounds, worker count, pair index, calls per batch, sequential ns/call, and threaded
ns/call. The measured raw output is retained locally in
`output/host-thread-investigation/chunks-run-{1,2,3}.txt`. No compilation or
initialization cost is included in the operation times.

The earlier limitations still apply: one Linux developer machine, unpinned
frequency/affinity, restricted scalar component bindings, and no production
thread-safety checks. Skewed stores, exact selections, spatial partitions,
representative application kernels, and chunk-size sweeps remain unmeasured.
Kernel setup outside the entity loop runs once per chunk, and row indices are
local to each chunk; a production API must document these observable semantics.

## Repository evidence

- [Host and selected dispatch, prepared contexts](../../../src/larecs/system.mojo)
- [Host row iteration](../../../src/larecs/iteration.mojo)
- [Ordered system lifecycle](../../../src/larecs/scheduler.mojo)
- [Structural lock limitations](../../../src/larecs/lock.mojo)
- [Existing shared mutable host bindings](../../../test/cpu_execution_test.mojo)
- [Existing CPU concurrency tests](../../../test/synchronization_test.mojo)
- [Synchronization design](../decisions/0016-kernel-memory-synchronization.md),
  [partition layout](../decisions/0014-growable-cluster-stores.md), and
  [benchmark methods](../../src/guide/benchmarks.md)
