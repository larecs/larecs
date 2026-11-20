+++
type = "docs"
title = "Share values with resources"
weight = 6
+++

Store a value that exists once per world, such as the step length, as a
resource, and let kernels and systems read or change it. Owning data, such as a
list of samples, reaches threaded and device kernels through a portable
resource. Results that many kernel invocations contribute to go into
per-particle output that one caller combines.
[Share time and configuration](../../start/shared_configuration) runs the first
example.

{{< example file="particles/configuration.mojo" region="time" >}}

{{< example file="particles/configuration.mojo" region="configuration" >}}

{{< example file="particles/configuration.mojo" region="world" >}}

`Time` and `Configuration` are resources. `world.resources.add` stores one
value of each, and `ConfigureTime` changes `Time` through
`context.world[].resources` before every movement step.

## Define a resource

A resource is a struct that conforms to
{{< api resource.ResourceType >}}, which requires `Copyable` and
`Deinitable`. Use `ResourceType` to name this constraint in your type
declaration. A world holds at most one value per resource type, and resource
types do not appear in the world's component list.

## Add, read, replace, and remove resources

{{< api ResourceStorage >}} manages the world's resources:

| Method | Effect | Raises when |
| --- | --- | --- |
| {{< api ResourceStorage.add >}} | Inserts values | A type is already present |
| {{< api ResourceStorage.get >}} | Returns a reference to the value | The type is missing |
| {{< api ResourceStorage.set >}} | Replaces existing values | Any type is missing; then no value changes. With `add_if_not_found=True`, it inserts missing types instead. |
| {{< api ResourceStorage.remove >}} | Removes values | A type is missing |

Do not keep a resource reference across removal or replacement.

## Declare kernel access

{{< example file="particles/configuration.mojo" region="kernel" >}}

A kernel declares its resources with {{< api Resources >}}, separately from its
component filter:

| Declaration | Access through the kernel |
| --- | --- |
| `read[T]()` | Read with `get` |
| `read_write[T]()` | Read and write with `get` |
| `write[T]()` | Write with `set` only, on the host; device kernels reject it |
| `Resources[T]()` | Read and write, like `read_write` |

Every declared resource must exist in the world when you call
{{< api SystemContext.run >}}; otherwise `run` raises, even when no entities
match.

Every kernel call in one `run` sees the same resource value. Because one `run`
can call the kernel several times, change per-step values in a system's
`update`, as `ConfigureTime` does, rather than in the kernel.

On the sequential host, a resource can own collections such as a `List`.
[Threaded and device kernels](../execution_backends#choose-a-target) accept only
pointer-free resources that own no memory; threaded kernels must also declare
them with `read`.

## Read owning data on any target

Read an owning collection from the particle kernel on both the host and a
device. A *portable resource* is a resource source with an adapter. It keeps the
owner on the host and gives each kernel a *kernel view*, a plain value that
points to the data on the kernel's target. This section and the next use the
[portable particle model](../execution_backends#the-portable-particle-model).

### Separate the owner from the kernel view

{{< example file="particles/portable_resources.mojo" region="owner_view" >}}

`Samples` is a {{< api BufferResource >}}, the built-in source for a contiguous
buffer of scalars. Its kernel view is {{< api ReadBuffer >}}, which has a length
and bounds-checked indexing. `Grid` is a custom
{{< api DevicePassableResource >}}: it owns a `List` and names the adapter that
creates its view, `GridView`. `GridView` holds a pointer to the samples and the
grid's dimensions, and `last()` reads the final sample. The pointer is
target-local: it refers to host memory in a host run and to device memory in a
device run.

### Prepare the view for each target

A {{< api ResourceAdapter >}} checks the current owner and builds the view for
the target of each call.

{{< example file="particles/portable_resources.mojo" region="adapter" >}}

- `validate` runs before every call, including calls that match no entities. It
  rejects empty or inconsistent grids, so `last()` never reads out of bounds.
- `bind_host` points the view at the owner's own list; it copies nothing.
- `prepare_device` uploads the samples through {{< api ResourceDeviceCache >}}
  slot 0 and returns a view that points to device memory. The cache keeps the
  device allocation between calls; by default, the samples upload again on every
  call. Use a distinct nonnegative slot per array.

### Request the source type in the kernel

{{< example file="particles/portable_resources.mojo" region="kernel" >}}

Inside `move`, `get[Samples]()` returns a `ReadBuffer` and `get[Grid]()` returns
a `GridView`, both immutable. Outside a kernel, `world.resources.get[Grid]()`
returns the owning `Grid`. Larecs registers the adapter when you add the source;
there is no separate registration call.

{{< example file="particles/portable_resources.mojo" region="check" >}}

The first step scales movement by `1 + 2` and ends at `x=0.75`. The edit changes
the last grid sample, so the second step scales by `1 + 3` and ends at
`(1.75, 3.5)`.

### Keep sources and views valid during a call

For the duration of a call, Larecs holds a *lease* on every bound source: it
keeps the source alive and in place, and looking it up, replacing it, or
removing it from inside the call raises. Two rules keep views valid:

- Keep views, their pointers, and references obtained from them inside the
  kernel invocation.
- Do not change, resize, or free the owner through a reference you kept from
  before the call while the call runs.

A lease protects the source's lifetime; it does not synchronize threads.

### Write through an adapter

`GridAdapter` supports reading only, so declare its source with `read`; the
`Resources[Grid]()` default means read-write and fails to compile. An adapter
that sets `supports_mutation` can provide a writable view for sequential host
calls, and one that also sets `supports_concurrent_mutation` can provide it for
threaded and device calls; both are guarantees from the adapter author.
Mutable adapters are experimental. The
[scatter example](https://github.com/larecs/larecs/blob/main/examples/scatter_resource.mojo)
shows the hooks and an atomic slot reservation. For most shared output, prefer
per-particle results.

## Coordinate shared writes

Compute one shared result, the total displacement of all particles, without a
data race. Each particle writes its own output in the kernel, and one caller
sums the outputs after `run` returns. This works on every target, including
threaded chunks and device threads, where many invocations run at once. A
resource or a mutable capture slot, by contrast, is one value that every
invocation would write.

{{< example file="particles/shared_outputs.mojo" region="kernel" >}}

`Displacement` belongs to each particle. `write[Displacement]()` grants set-only
access, so the kernel must `set` the output on every row it visits. No two rows
share an output, so the kernel needs no synchronization on any target.

{{< example file="particles/shared_outputs.mojo" region="reduction" >}}

`run` is synchronous, so the query sees every written `Displacement`. One caller
sums all 37 outputs to `(9.25, 18.5)`; nothing writes `total` concurrently. For a
parallel reduction, write partial results to disjoint per-particle or per-group
components, then combine them in a later `run`.

### Update data you own with atomic or guarded values

Larecs does not bind synchronization primitives to kernels. These primitives
work on storage you own, outside the world:

{{< example file="particles/shared_outputs.mojo" region="primitives" >}}

- {{< api AtomicValue >}} owns a `UInt32` or `Int32` scalar, and
  {{< api AtomicView >}} borrows it. `fetch_add` returns the previous value.
  `compare_exchange` reports whether it exchanged and which value it observed.
  Operations use relaxed ordering unless you pass an ordering, such as
  `store[Ordering.RELEASE]` and `load[Ordering.ACQUIRE]`, at compile time.
- {{< api Synchronized >}} owns guarded data, and {{< api SyncView >}} borrows
  it. `try_read` and `try_write` make one attempt and never wait. Check
  {{< api TryAccess.is_acquired is_acquired >}} before you consume the attempt
  with `take`. Several readers may hold the value at once; a writer excludes
  everyone else. The guard releases at scope exit or through `release`.

A false `is_acquired` means *Busy*: the single attempt met a conflicting guard,
a state that changed during the attempt, or the maximum reader count. Larecs
does not retry. Record the unfinished work for a later pass, or skip the update
only if your application can lose it.

## Run the programs

From the repository root, run:

```sh
pixi run mojo run -I src examples/particles/portable_resources.mojo
pixi run mojo run -I src examples/particles/shared_outputs.mojo
```

A PASS line for the device means the kernel read both views on the accelerator;
a SKIP line means only the host ran.

## Failures and limits

| Failure | Cause and fix |
| --- | --- |
| `run` raises because `Time` is missing | Add `Time` with `world.resources.add` before you start the scheduler. |
| Compile error on resource access | Check the kernel's `Resources` declaration; the component filter does not grant resource access. |
| `run` raises a grid validation error, even with no matching entities | The owner is invalid. Make the dimensions match the sample count before the call. |
| Compile error: mutable access requires `Adapter.supports_mutation` | The source is declared writable. Declare it with `read`, or implement a writer view. |
| Crash or wrong values from a view pointer | The view points to memory that does not belong to the owner or the device cache, or an earlier reference changed the owner during the call. Return owner-backed or cache-backed memory only. |
| Wrong totals from a shared resource or capture | Several invocations wrote one value. Write per-particle output and reduce after `run`. |
| `try_read` or `try_write` returns Busy | Do not spin; defer the work to a later pass. |
| Compile error for an ordering, compare-exchange, or guard on an Apple GPU | Apple devices support only relaxed or acquire loads, relaxed or release stores, and relaxed add and subtract. Use per-particle output instead. |
| Compile error when an `AtomicView` or `SyncView` is in a resource or capture | Views do not transfer to kernels. Use per-particle output, or a mutable adapter that manages its own atomic buffer. |
| Ordinary data written next to a relaxed counter is not visible | Relaxed operations order nothing else. Use release stores and acquire loads to publish data. |

## Complete programs

{{< example file="particles/portable_resources.mojo" full=true >}}

{{< example file="particles/shared_outputs.mojo" full=true >}}

## Next steps

[Run kernels on threads and devices](../execution_backends) runs these kernels
concurrently and skips uploads of unchanged sources.
