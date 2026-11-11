+++
type = "docs"
title = "Use portable resources"
weight = 4
+++

Read an owning collection, such as a list of samples, from the particle kernel
on both the host and a device. An ordinary resource that owns memory works on
the sequential host only, because Larecs cannot copy its heap data to a device
byte by byte. A *portable resource* is a resource source with an adapter: it
keeps the owner on the host and gives each kernel a *kernel view*: a plain value that points to the data on the kernel's
target.

Start with [Share values with resources](../../shared_resources) and
[Execute on a device](../device). Mutable portable resources are
[experimental](../../../reference/compatibility); this page uses read-only
views.

## Separate the owner from the kernel view

The particle types follow the [portable particle model](../#the-portable-particle-model),
and `Time` stays an ordinary read-only resource.

{{< example file="particles/portable_resources.mojo" region="model" >}}

The stage adds two *resource sources*, the owning values stored in the world:

{{< example file="particles/portable_resources.mojo" region="owner_view" >}}

`Samples` is a {{< api BufferResource >}}, the built-in source for a contiguous
buffer of scalars. Its kernel view is {{< api ReadBuffer >}}, which has a length
and bounds-checked indexing. `Grid` is a custom
{{< api DevicePassableResource >}}: it owns a `List` and names the adapter that
creates its view, `GridView`. `GridView` holds a pointer to the samples and the
grid's dimensions, and `last()` reads the final sample. The pointer is
target-local: it refers to host memory in a host run and to device memory in a
device run.

## Prepare the view for each target

A {{< api ResourceAdapter >}} checks the current owner and builds the view for
the target of each call.

{{< example file="particles/portable_resources.mojo" region="adapter" >}}

- `validate` runs before every call, including calls that match no entities. It
  rejects empty or inconsistent grids, so `last()` never reads out of bounds.
- `bind_host` points the view at the owner's own list; it copies nothing.
- `prepare_device` uploads the samples through {{< api ResourceDeviceCache >}}
  slot 0 and returns a view that points to device memory. The cache keeps the
  device allocation between calls; by default, the samples upload again on
  every call.

## Request the source type in the kernel

The kernel declares and looks up resources by their source type:

{{< example file="particles/portable_resources.mojo" region="kernel" >}}

Inside `move`, `get[Samples]()` returns a `ReadBuffer` and `get[Grid]()` returns
a `GridView`, both immutable. Outside a kernel, `world.resources.get[Grid]()`
returns the owning `Grid`. Larecs registers the adapter when you add the source;
there is no separate registration call.

The driver adds both sources, edits the grid between steps, and checks that
validation also runs without matching entities:

{{< example file="particles/portable_resources.mojo" region="check" >}}

The first step scales movement by `1 + 2` and ends at `x=0.75`. The edit changes
the last grid sample, so the second step scales by `1 + 3` and ends at
`(1.75, 3.5)`.

From the repository root, run:

```sh
pixi run mojo run -I src examples/particles/portable_resources.mojo
```

A PASS
line for the device means the kernel read both views on the accelerator; a SKIP
line means only the host ran.

## Keep sources and views valid during a call

For the duration of a call, Larecs holds a *lease* on every bound source: it
keeps the source alive and in place, and looking it up, replacing it, or
removing it from inside the call raises. Two rules keep views valid:

- Keep views, their pointers, and references obtained from them inside the
  kernel invocation.
- Do not change, resize, or free the owner through a reference you kept from
  before the call while the call runs.

A lease protects the source's lifetime; it does not synchronize threads.
[Structural locks are not mutexes](../../../reference/compatibility#structural-locks-are-not-mutexes),
and neither are leases. The
[adapter reference](../../../reference/resources#adapter-contracts) lists the
remaining rules for adapter authors.

## Variations

### Write through an adapter

`GridAdapter` supports reading only, so declare its source with `read`; the
`Resources[Grid]()` default means read-write and fails to compile. An adapter
that sets `supports_mutation` can provide a writable view for sequential host
calls, and one that also sets `supports_concurrent_mutation` can provide it for
threaded and device calls. The
[mutable adapter reference](../../../reference/resources#mutable-adapters)
and the [scatter example](https://github.com/larecs/larecs/blob/main/examples/scatter_resource.mojo)
show the hooks and an atomic slot reservation. For most shared output, prefer
[per-particle results](../shared_writes).

### Skip unchanged uploads

With [device-copy reuse](../copy_reuse) enabled, a read-only source that has not
changed since the last device call skips `prepare_device` and reuses its view.

## Failures and limits

| Failure | Cause and fix |
| --- | --- |
| `run` raises a grid validation error, even with no matching entities | The owner is invalid. Make the dimensions match the sample count before the call. |
| Compile error: mutable access requires `Adapter.supports_mutation` | The source is declared writable. Declare it with `read`, or implement a writer view. |
| Crash or wrong values from a view pointer | The view points to memory that does not belong to the owner or the device cache, or an earlier reference changed the owner during the call. Return owner-backed or cache-backed memory only. |
| Stale samples with copy reuse enabled | The owner changed through a reference that Larecs does not track. Reacquire it with `get` after each run, or [invalidate it](../copy_reuse#invalidate-a-write-larecs-cannot-see). |

## Complete program

{{< example file="particles/portable_resources.mojo" full=true >}}

## Next steps

- [Reuse unchanged device copies](../copy_reuse) avoids repeated uploads.
- [Bindings, transfers, and revisions](../../../inside/architecture/transfers#sources-and-target-local-views)
  explains leases, adapter views, and their lifetimes.
