+++
type = "docs"
title = "Run kernels on threads and devices"
weight = 7
+++

Choose where a particle kernel runs and how it receives data. By default,
{{< api SystemContext.run >}} calls a kernel sequentially on the host. You can
split one call into chunks on host worker threads, run it on an accelerator
such as a GPU, pass it step-local values, and skip device uploads of data that
has not changed. Threaded execution, device execution, and device-copy reuse are
experimental.

Start with [Update entities with systems and kernels](../systems_kernels) and
[Share time and configuration](../../start/shared_configuration).

## Choose a target

| Contract | Sequential host | Threaded host | Device |
| --- | --- | --- | --- |
| Call form | `context.run[move]()` | `context.run[move, backend=ExecutionBackend.HOST_THREADED]()` | `context.run[move, backend=ExecutionBackend.DEVICE]()` |
| Kernel | Thin kernel or lexical closure | Thin kernel without captures | Thin kernel |
| Accessed components | Any `ComponentType`, including owning ones | Pointer-free values that own no memory | `TrivialRegisterPassable` |
| Ordinary resources | Any declared access | `read` only, pointer-free values | `read` or `read_write`, pointer-free values |
| Owning resource data | Ordinary resource | [Portable resource](../shared_resources#read-owning-data-on-any-target) | Portable resource |
| Explicit captures | Read and mutable slots | Rejected | Read and mutable slots |
| Kernel invocations | One per matching physical store | One per kernel chunk | One launch over all matching rows |

A *thin kernel* is a named `def` function that `run` receives as a compile-time
parameter, as in `context.run[move]()`. It captures no local variables. Every
target is synchronous: `run` returns after all invocations finish and, on a
device, after written data is back on the host. A failed call does not roll back
writes that already happened.

On every target, a row's `idx` counts from zero within one invocation, so the
same entity can have a different `idx` in the next call. Identify entities with
{{< api Entity >}} handles, and do not index shared output with `idx`.

## The portable particle model

Every program on this page uses the same variant of the particle types:

{{< example file="particles/device.mojo" region="model" >}}

It differs from the first simulation in two ways, both needed for device
execution:

- The fields are `Float32`, because Apple GPUs have no 64-bit floating-point
  arithmetic. The host runs use `Float32` too, so host and device compute the
  same values.
- `Position` and `Velocity` conform to `TrivialRegisterPassable`. Device
  execution requires it of every component a kernel accesses, because Larecs
  copies those components to the device byte by byte.

Threaded host execution needs neither change. It accepts any component whose
fields hold no pointers and own no memory, such as the `Float64` types of the
first simulation. `Time` needs no trait on any target, because Larecs checks
resources by their fields.

## Run threaded host kernels

Split one movement call into chunks that run concurrently on host worker
threads. Use this when a single kernel call covers many independent rows and
dominates a step. Only the rows of one call are split; systems still run one
after another in registration order.

{{< example file="particles/threaded.mojo" region="kernel" >}}

Each row writes only its own `Position`, so no two chunks write the same data.
`Resources().read[Time]()` declares `Time` read-only, so all chunks share one
immutable value. Opt in for one call with `backend=ExecutionBackend.HOST_THREADED`:

{{< example file="particles/threaded.mojo" region="system" >}}

Then give the world more than one worker:

{{< example file="particles/threaded.mojo" region="check" >}}

{{< api ThreadedExecutionConfig >}} sets the number of tasks Larecs submits per
call, not reserved cores. `chunks_per_worker=2` targets two chunks per worker,
and `min_parallel_rows=0` removes the row cutoff, so the 4097 particles split
into chunks. The driver runs the same two steps sequentially, threaded with one
worker, and threaded with four workers, each in a fresh world, and checks that
every particle ends at `(0.5, 1.0)`.

### How Larecs splits the rows

Larecs splits each matching physical store into *kernel chunks*: contiguous row
ranges, each passed to one kernel invocation. Workers claim chunks in an
unspecified order. This changes what code outside the row loop sees:

- Code before or after the `for` loop runs once per chunk, not once per store.
- A row's `idx` restarts at zero in each chunk.
- Work that reads rows of other chunks needs a later `run`.

The default configuration has one worker, four chunks per worker, and a cutoff
of 65,536 matched rows. With one worker, or with fewer matched rows than
`min_parallel_rows`, a `backend=ExecutionBackend.HOST_THREADED` call runs sequentially, once per physical
store. Keep `backend=ExecutionBackend.HOST_THREADED` in the system and set the worker budget per world;
the compile-time eligibility checks apply either way.

Each threaded call takes one structural lock in addition to those already held,
even when it runs sequentially. A structural lock keeps rows in place; it does
not serialize threads, so shared state still needs a race-free write strategy,
as in [Coordinate shared writes](../shared_resources#coordinate-shared-writes).

## Execute on a device

Run the same movement kernel on an accelerator and check that it produces the
same positions as the host. Use this when a kernel does enough arithmetic per
particle to outweigh copying data to the device and back. Device execution needs
the repository's pinned Mojo and MAX environment and a supported accelerator.

{{< example file="particles/device.mojo" region="kernel" >}}

{{< example file="particles/device.mojo" region="system" >}}

`Move[ExecutionBackend.DEVICE]()` runs `move` on the device, and
`Move[ExecutionBackend.HOST]()` runs it sequentially on the host, which is also
the default when you omit `backend`. The {{< api ExecutionBackend >}} value is a
compile-time parameter, so each system specialization runs on one target.

### Let the filter decide what moves

Larecs copies only the data the kernel declares. For each call, it packs the
matching rows of every physical store into contiguous device columns, runs the
kernel once over all of them, and copies written columns back to their original
rows.

![Readable Position and Velocity ranges pack from two host stores into device columns; only written Position scatters back after synchronization.](/images/device-transfer.svg)

*Access declarations determine transfer directions.*

| Declaration | Upload before the kernel | Copy back after the kernel |
| --- | --- | --- |
| `include[Position]()` | Yes | Yes |
| `read[Velocity]()`, `Resources().read[Time]()` | Yes | No |
| `write[T]()` | No; the kernel must `set` every row it visits | Yes |

Rows that the filter does not match stay untouched. When no rows match, Larecs
still validates the declared resources but allocates, uploads, and launches
nothing.

### Compare the device with the host

The driver runs two steps on 37 moving particles and one unmatched marker, once
per target, each in a fresh world.

{{< example file="particles/device.mojo" region="parity" >}}

Every mover ends at `(0.5, 1.0)`, the marker stays at `(-3, -3)`, and the device
sums match the host sums. `backend=ExecutionBackend.DEVICE` never falls back to
the host: without a usable accelerator, `run` raises, even when no rows match.
To choose at run time, branch on `has_accelerator()` and call each
specialization explicitly, as the driver does.

### How device threads visit rows

On the host, a kernel invocation covers one physical store or one kernel chunk.
On a device, one launch covers all packed rows, and each device thread runs the
kernel body. The `for` loop over the context uses *grid-stride iteration*: each
thread starts at its global thread index and advances by the total number of
launched threads, so every row is visited exactly once.

![Sequential host calls each matching store, threaded host calls disjoint chunks, and device threads stride through packed matching rows.](/images/execution-mapping.svg)

*One row loop, three invocation mappings.*

Code outside the `for` loop runs once per device thread. A row's `idx` is its
offset in the packed rows.

## Pass local values to kernels

Give the kernel a step-local scale and get a particle count back without storing
either value as a resource. Use a lexical closure when the kernel runs
sequentially on the host, and explicit capture slots when it must also run on a
device. Threaded execution accepts neither; pass its inputs through read-only
resources or components.

### Borrow locals with a closure on the host

A *lexical closure* is a `def` nested inside another function that names the
local variables it uses in a capture list:

{{< example file="particles/lexical_closure.mojo" region="closure" >}}

The capture list `{imm scale, mut visits}` borrows `scale` read-only and
`visits` mutably. `context.run(move)` selects the overload that takes a callable
value; it runs only sequentially on the host. Larecs calls `move` once per
matching physical store, and `visits` increases once per row.

{{< example file="particles/lexical_closure.mojo" region="check" >}}

The extra `Int32` component gives `climber` its own physical store, so `move`
runs twice and `visits` counts rows across both calls.

### Declare explicit slots for a thin kernel

A thin kernel declares ordered *capture slots* with {{< api Captures >}}. The
system binds a local value to each slot when it calls `run`, on the host or on a
device.

{{< example file="particles/captures.mojo" region="kernel" >}}

Slot 0 is a {{< api ReadCapture >}} input; `get[0]()` returns its value. Slot 1
is a {{< api MutCapture >}} output. Every invocation, and on a device every
thread, sees the same output value, so only one writer may update it:

- On the host, each invocation covers one physical store and adds its own row
  count, `context.length`. Sequential invocations never overlap.
- On a device, `comptime if is_gpu()` compiles a branch in which only the thread
  with global index zero adds the packed row count.

A thread-zero branch is not a barrier; it works here only because no thread
reads another thread's result.

{{< example file="particles/captures.mojo" region="system" >}}

{{< api read_capture >}} and {{< api mut_capture >}} borrow `scale` and
`processed` until `run` returns, in the declared slot order. On a device, Larecs
uploads every binding on each call and copies the mutable slot back before `run`
returns, so `processed` holds 37 at the assertion. A capture lives for one call;
a value that persists between steps or owns memory belongs in a
[resource](../shared_resources).

## Reuse unchanged device copies

Skip uploading data that has not changed since the last device call. Use this
after the kernel matches the host and a measurement shows that uploads matter.
Reuse is off by default and set per world. Written outputs still copy back after
every call.

The kernel and system stay unchanged. Enable reuse on the world with
{{< api World.reuse_device_copies >}}:

{{< example file="particles/copy_reuse.mojo" region="sequence" >}}

Larecs keeps a *revision* for each resource and for each component column of a
physical store, and advances it whenever the host may have changed that data.
With reuse enabled, a device call uploads a resource or column only when the
revision of its *device copy*, the bytes already on the device, differs from the
current one. In the sequence:

- `read` calls leave the revisions unchanged, so the second step reuses every
  input.
- `get` through mutable storage advances the revision whether or not you write,
  so the step after `get[Time]().delta = 0.5` uploads `Time` again.
- A successful device call leaves the written `Position` current on both sides,
  so the next call can skip its upload too.

![First use uploads, an unchanged revision reuses bytes, and a tracked write or explicit invalidation makes the next call upload again; allocation capacity persists.](/images/device-copy-reuse.svg)

*Retained capacity does not prove that its contents are current.*

Structural changes, spatial maintenance, and kernels that declare writes also
advance revisions. A component copy is reused only for the same contiguous row
range at the same packed offset, so alternating filters or selections can cause
uploads of unchanged values.

### Invalidate a write Larecs cannot see

Larecs advances a revision when you call `get`, not when you later write through
the reference it returned. The sequence keeps `time_ptr` across a run and then
writes through it, so Larecs cannot see that write.
`scheduler.world.resources.invalidate_device[Time]()` marks the device copy of
`Time` stale. For writes through raw pointers to several resources or columns,
{{< api World.invalidate_device_copies >}} marks every device copy stale.
Reacquiring references with `get` after each run avoids the problem.

{{< example file="particles/copy_reuse.mojo" region="check" >}}

The host, default device transfers, and device transfers with reuse all end at
`(4.5, 7.0)`. `world.reuse_device_copies(False)` discards the reuse records; the
next device call uploads every input again.

## Run on a selection

{{< api EntitySelection.run >}} accepts the same `threaded` and `backend`
parameters and runs only the selection's rows. A device call packs only those
rows.

## Run the programs

From the repository root, run each stage:

```sh
pixi run mojo run -I src examples/particles/threaded.mojo
pixi run mojo run -I src examples/particles/device.mojo
pixi run mojo run -I src examples/particles/lexical_closure.mojo
pixi run mojo run -I src examples/particles/captures.mojo
pixi run mojo run -I src examples/particles/copy_reuse.mojo
```

A PASS line for the device means the kernel ran on the accelerator and matched
the host; a SKIP line means this machine has no supported accelerator and only
the host ran.

## Failures and limits

| Failure | Cause and fix |
| --- | --- |
| `Threaded components require pointer-free trivial plain values` | An accessed component holds a pointer or owns memory. Remove it from the filter, or keep that data in a portable resource. |
| `Threaded resources require explicit read access` | The kernel declares an ordinary resource writable, including through the `Resources[Time]()` read-write default. Declare it with `read`, or write per-particle output. |
| `Threaded resources require pointer-free plain values or DevicePassableResource adapters` | A `read` resource owns memory or holds a pointer. Use a [portable resource](../shared_resources#read-owning-data-on-any-target). |
| `ThreadedExecutionConfig` raises | `workers` and `chunks_per_worker` must be positive, their product must fit in an `Int`, and `min_parallel_rows` must not be negative. |
| Structural lock exhaustion in a threaded call | Live queries and selections, even empty ones, hold the other locks. End those you no longer need. |
| `run` raises that DEVICE requires accelerator support or a working device context | No usable accelerator. Fix the toolchain or select `ExecutionBackend.HOST`; there is no fallback. |
| Compile error: every accessed component type must be device-safe | Make the component `TrivialRegisterPassable`. Only accessed components are checked. |
| Compile error: device resources require pointer-free trivial plain values | The resource owns memory. Use a portable resource. |
| Compile error: device write-only resources are unsupported | Declare an ordinary device resource with `read` or `read_write`. |
| Compile error for a lexical closure with `DEVICE` or `HOST_THREADED` | Lexical closures run only sequentially on the host. Use explicit capture slots for a device. |
| Compile error on the capture slot count, type, or mutability | Bind one value per slot in declaration order, with the declared type. One local cannot be bound read-only and mutably in the same call. |
| Wrong result from a mutable capture slot | The slot provides no synchronization. Use one writer, or [per-particle output](../shared_resources#coordinate-shared-writes). |
| The device reads old values with reuse enabled | A write went through a reference kept from before a run, or a raw pointer. Reacquire references with `get` after each run, or invalidate the copy. |
| `run` raises about a missing resource, even with no matching rows | Add every declared resource during setup. |
| No speedup | Dispatch, transfers, and preparation cost time. Measure complete steps before you keep a target or change the threaded cutoff. |

If a device transfer or synchronization fails, Larecs discards outputs it has
not yet written to the host. When completion stays unknown, the world rejects
further execution and must be replaced.

## Complete programs

{{< example file="particles/threaded.mojo" full=true >}}

{{< example file="particles/device.mojo" full=true >}}

{{< example file="particles/lexical_closure.mojo" full=true >}}

{{< example file="particles/captures.mojo" full=true >}}

{{< example file="particles/copy_reuse.mojo" full=true >}}

## Next steps

- [Share values with resources](../shared_resources) reads owning collections
  on the device and combines results from many invocations.
- [Maintain particle locality](../spatial_locality) groups nearby particles in
  memory.
