+++
type = "docs"
title = "Resources"
weight = 50
+++

Not all data in a world is associated with
specific entities. This often applies to
parameters (such as a time step),
global state variables (such as the current time),
or spatial data structures (such as a grid displaying
entity positions). These data are called resources.

## Defining resources

Similar to components, resources are defined via
structs. That is, each resource has a specific
type, and having two resources of the same type is not
possible.

However, in contrast to components, the (potentially)
used resources do not need to be known at compile time
but can be dynamically added to the world and are
keyed by their runtime type name.

```mojo {doctest="guide_resources" global=true}
from larecs import (
    World,
    Entity,
    SystemContext,
    KernelContext,
    Filter,
    Resources,
    ResourceType,
)
from std.testing import assert_equal, assert_false, assert_true

@fieldwise_init
struct Time(ResourceType, TrivialRegisterPassable):
    var time: Float64

@fieldwise_init
struct Temperature(ResourceType):
    var temperature: Float64

@fieldwise_init
struct SelectedEntities(ResourceType):
    var entities: List[Entity]
```

```mojo {doctest="guide_resources" global=true hide=true}
@fieldwise_init
struct Position(Copyable, Movable):
    var x: Float64
    var y: Float64

@fieldwise_init
struct Velocity(Copyable, Movable):
    var dx: Float64
    var dy: Float64
```

A resource must conform to `ResourceType` (`Copyable & Deinitable`). The
example also conforms to `TrivialRegisterPassable` so it can be used by the
device kernel path described below; host-only resources do not need that trait.

## Adding and accessing resources

The examples below access a `World` directly to introduce the resource API.
During application execution, resource changes should generally be owned by a
[system](../systems_scheduler), keeping them in the same scheduled lifecycle
as entity and component changes. Its lifecycle methods can access resources
through `context.world[].resources`.

Resources can be accessed and added via the `resources` field
of {{< api World >}}. Adding a resource is done via the
{{< api ResourceStorage.add resources.add >}} method:

```mojo {doctest="guide_resources" global=true hide=true}
def main() raises:
    var world = World[Position, Velocity]()
```

```mojo {doctest="guide_resources" global=true}
    # Add the `Time` resource
    world.resources.add(Time(0.0))
```

The `resources` attribute also allows us to access and change resources via
{{< api ResourceStorage.get get >}} and {{< api ResourceStorage.set set >}}.
Unlike their [component-related counterparts](../changing_entities), these
operations need no entity argument: a resource is selected only by its type.

`ResourceStorage.get` intentionally returns a reference with `UnsafeAnyOrigin`,
preserving the mutability of the storage access. It should keep this origin
until Mojo's origin system can model the ownership relation between the
resource container and its separately allocated resource values. Tying the
returned reference to the storage origin is not a suitable interim replacement.

```mojo {doctest="guide_resources" global=true}
    # Change a resource value via a reference
    world.resources.get[Time]().time = 1.0

    # Get a reference to a resource
    ref time = world.resources.get[Time]()

    # Change the resource value via the reference
    time.time = 2.0

    # Replace the entire resource through the returned reference
    world.resources.get[Time]() = Time(3.0)
    assert_equal(world.resources.get[Time]().time, 3.0)
```

The {{< api ResourceStorage.add add >}} and
{{< api ResourceStorage.set set >}} methods can add or set multiple resources
at once.
For example, consider the additional resources `Temperature`
and `SelectedEntities`, each defined just like `Time` above.

We can add and set them as follows:

```mojo {doctest="guide_resources" global=true}
    # Add multiple resources
    world.resources.add(
        Temperature(20.0),
        SelectedEntities(List[Entity]())
    )

    # Set multiple resources
    world.resources.set(
        Temperature(30.0),
        Time(2.0)
    )
```

These operations are strict by default:

- `add` raises if a requested resource type already exists.
- `get` and `remove` raise if the requested resource does not exist.
- `set` raises if any requested resource does not exist and does not update any
  of them. Use `set[add_if_not_found=True](...)` when missing resources should
  be inserted.

For example, `set` can explicitly recreate a missing resource:

```mojo {doctest="guide_resources" global=true}
    world.resources.remove[Temperature]()
    world.resources.set[add_if_not_found=True](Temperature(25.0))
    assert_equal(world.resources.get[Temperature]().temperature, 25.0)
```

In contrast to components, resources can
be "complex" types with heap-allocated memory,
as demonstrated above with `SelectedEntities`.
We can use them to store arbitrary amounts of data.

```mojo {doctest="guide_resources" global=true}
    # Create entities and add them to the selected entities
    for i in range(10):
        var entity = world.storage.add_entity(Position(Float64(i), Float64(i)))
        world.resources.get[SelectedEntities]().entities.append(entity)
```

## Using resources in kernels

A kernel declares the resource types it may access with a compile-time
{{< api Resources >}} list. Pass that list as the second parameter of
{{< api KernelContext >}}, then retrieve a resource through
`context.resources.get[T]()`:

```mojo {doctest="guide_resources" global=true}
    var mover = world.storage.add_entity(
        Position(0.0, 0.0), Velocity(2.0, 1.0)
    )

    def move_with_time(
        context: KernelContext[
            Filter().include[Position].read[Velocity](),
            Resources[Time](),
        ]
    ):
        ref time = context.resources.get[Time]()
        for entity in context:
            ref pos = entity.get[Position]()
            ref vel = entity.get[Velocity]()
            pos.x += vel.dx * time.time
            pos.y += vel.dy * time.time

    var context = SystemContext(world)
    context.run[move_with_time]()

    # `Time.time` is 2.0, so the velocity moved the entity by (4.0, 2.0)
    ref position = world.storage.get[Position](mover)
    assert_equal(position.x, 4.0)
    assert_equal(position.y, 2.0)
```

Here, `Resources[Time]()` makes `Time` available to `move_with_time`.
`get[Time]()` returns a mutable reference, so a kernel may also update the
resource. Such changes remain in the world's resource storage after the
kernel finishes. Every declared resource must already have been added to the
world; otherwise `SystemContext.run` raises an error.

The direct `SystemContext` construction keeps this example focused on the
resource API. In application logic, call `run` from a system lifecycle method,
as shown in [Systems and the scheduler](../systems_scheduler).

A resource is one shared mutable value for every entity processed by the
kernel. Concurrent reads need no special handling. Writes from GPU threads must
be synchronized or otherwise made race-free; in particular, do not update a
shared resource once per entity without an atomic or reduction strategy.
Writing per-entity results to components and reducing them in a separate step
is often simpler. Also avoid target-dependent side effects outside the entity
loop: the host calls the kernel once per matching archetype, while the device
processes all matching rows in one launch.

Host kernels may also capture surrounding values and access resources through
`context.run(kernel)`. See [Capturing host kernels](../systems_scheduler#capturing-host-kernels)
for an example. Device entry points use the non-capturing `context.run[kernel]()` form.

To run this same kernel on a device, replace its host `run` call with:

```mojo
    context.run[move_with_time, on_device=True]()
```

For device execution, components must conform to `TrivialRegisterPassable`.
Ordinary resources need a supported pointer-free representation with trivial
copy, move, and destruction. Numeric values, `Bool`, and aggregates of those
values are accepted without declaring `TrivialRegisterPassable`. Owning
collections, host pointers, and opaque representations (including fixed `Array`
fields in this increment) are rejected. Host kernels still support owning resources.

## Resource permissions

`Resources[T]()` preserves `read_write` access. Prefer explicit declarations:

```mojo
comptime required = Resources().read[Time]().read_write[Statistics]()
```

A `read` getter is immutable and its device buffer is never downloaded.
`read_write` permits mutable `get[T]()` and copies device changes back after
successful completion. Host `write[T]()` offers `set[T](value)` only; it rejects
`get[T]()`. Device write-only resources are unsupported because conditional
shared writes could publish uninitialized data. Applications must synchronize
concurrent writes to ordinary shared resources themselves.

## Portable owning resources

Use `BufferResource` for a contiguous scalar collection. The same kernel requests
the original source type and receives its read-only `ReadBuffer` view on both
backends:

```mojo
from larecs import BufferResource, Filter, KernelContext, Resources, SystemContext, World

comptime Samples = BufferResource[DType.int32]
comptime required = Resources().read[Samples]()

def add_sample(context: KernelContext[Filter().include[Int32](), required]):
    ref samples = context.resources.get[Samples]()
    for entity in context:
        entity.get[Int32]() += samples[0]

def main() raises:
    var world = World[Int32]()
    world.resources.add(Samples([Int32(7), Int32(8)]))
    _ = world.storage.add_entities(Int32(1), count=37)
    var context = SystemContext(world)
    context.run[add_sample]()
    context.run[add_sample, on_device=True]()
    world.resources.get[Samples]().samples[0] = 9
    context.run[add_sample]()
```

Device execution requires a working accelerator. Samples are uploaded every
invocation; device allocation capacity is reused. The host source remains
unchanged by device view access. `ReadBuffer` has `len` and bounds-checked
indexing; empty buffers have length zero and must not be indexed.

### Defining a custom portable resource

Implement `DevicePassableResource` when your resource owns data that cannot be
copied directly to a device, or needs a domain-specific kernel API. Keep the
owning host type, its kernel view, and transfer logic separate:

| Type | Contains | Used by |
| --- | --- | --- |
| `Grid` | Owning `List` and current dimensions | Application code between runs |
| `GridView` | Immutable sample pointer, dimensions, and sampling methods | The same kernel on either backend |
| `GridAdapter` | Static validation and view preparation methods | Larecs during `run` |

The source declares its `Adapter` as a compile-time member. The adapter declares
the matching `Source` and a `View[mut: Bool]` mapping; it needs no constructor
or instance fields. A read-only adapter maps both access kinds to one view type.
The source's `View` and `KernelView` (an alias for `View[False]`) default to the
adapter's mapping. Every method reads the current source, including
configuration such as dimensions.

This complete example uses a rectangular grid. Its view exposes `last()` to
keep pointer arithmetic inside the resource API. A scientific view can instead
provide interpolation, coordinate lookup, or other read-only operations.

```mojo {doctest="guide_custom_resource" global=true hide=true}
# SKIP_DEBUG
# SKIP_ASAN
```

```mojo {doctest="guide_custom_resource" global=true}
from std.sys import has_accelerator
from std.testing import assert_equal
from larecs import (
    DevicePassableResource,
    ResourceAdapter,
    ResourceDeviceCache,
    Filter,
    KernelContext,
    Resources,
    SystemContext,
    World,
)


@fieldwise_init
struct Grid(DevicePassableResource):
    """Owns current host samples and grid metadata."""

    comptime Adapter = GridAdapter
    var values: List[Int32]
    var width: Int
    var height: Int


@fieldwise_init
struct GridView(TrivialRegisterPassable):
    """Portable read-only descriptor over current target-local samples."""

    var values: Pointer[Int32, ImmUntrackedOrigin]
    var width: Int
    var height: Int

    def last(self) -> Int32:
        """Reads the last sample of this validated nonempty grid.

        Returns:
            Last grid sample.
        """
        return self.values[unsafe_offset=self.width * self.height - 1]


struct GridAdapter(ResourceAdapter):
    """Stateless adapter using current dimensions and cached sample capacity."""

    comptime Source = Grid
    comptime View[mut: Bool] = GridView

    @staticmethod
    def validate(source: Self.Source) raises:
        """Checks a nonempty rectangular grid before preparing either target.

        Args:
            source: Current host owner.

        Raises:
            Error: If dimensions overflow or do not match sample storage.
        """
        if source.width <= 0 or source.height <= 0:
            raise Error("This grid requires positive dimensions")
        if source.width > 9223372036854775807 // source.height:
            raise Error("Grid dimensions overflow")
        if source.width * source.height != len(source.values):
            raise Error("Grid dimensions must match sample count")

    @staticmethod
    def bind_host(source: Self.Source) raises -> Self.View[False]:
        """Borrows immutable samples from the validated host owner.

        Args:
            source: Current validated source.

        Raises:
            Error: If descriptor preparation fails.

        Returns:
            Descriptor over host samples.
        """
        return {
            Pointer[Int32, ImmUntrackedOrigin](
                unsafe_from_address=Int(source.values.unsafe_ptr())
            ),
            source.width,
            source.height,
        }

    @staticmethod
    def prepare_device(
        source: Self.Source, mut cache: ResourceDeviceCache
    ) raises -> Self.View[False]:
        """Uploads current samples and returns the same descriptor type.

        Args:
            source: Current validated source.
            cache: Source-type, context-local allocation cache.

        Raises:
            Error: If sample allocation or upload fails.

        Returns:
            Descriptor over device samples.
        """
        return {
            cache.upload[Int32](0, Span(source.values)),
            source.width,
            source.height,
        }

```

`validate` runs before preparation on either backend, even when no entities
match. Check sample counts and arithmetic here; a trivial view descriptor does
not prove that its pointer indexing is valid. This grid rejects empty storage,
so `last()` is always defined after successful validation.

`bind_host` borrows the owner's samples without copying. Its untracked immutable
pointer relies on Larecs retaining the source throughout the invocation; it must
never point into a temporary local collection. `prepare_device` uploads the
samples through the supplied cache and returns the same descriptor with a device
pointer. Larecs uploads the descriptor itself; the adapter does not need to.

### Registering and using the custom resource

Declare read access using the **source type**, and keep that same type in
`get[Grid]()`. Inside the kernel the result is an immutable `GridView`, on both
host and device. Outside the kernel, `world.resources.get[Grid]()` returns the
owning `Grid` for edits. The following continues the example above:

```mojo {doctest="guide_custom_resource" global=true}
comptime required = Resources().read[Grid]()


def add_grid_sample(
    context: KernelContext[Filter().include[Int32](), required]
):
    """Adds the grid's last sample to each matching component.

    Args:
        context: Component rows and the read-only GridView binding.
    """
    ref grid = context.resources.get[Grid]()
    for entity in context:
        entity.get[Int32]() += grid.last()


def main() raises:
    """Uses one custom resource and kernel on the host and, if available, device.

    Raises:
        Error: If resource validation, execution, or a result check fails.
    """
    var world = World[Int32]()
    world.resources.add(Grid([Int32(1), Int32(2), Int32(3), Int32(9)], 2, 2))
    var entity = world.storage.add_entity(Int32(1))
    var context = SystemContext(world)

    context.run[add_grid_sample]()
    assert_equal(world.storage.get[Int32](entity), 10)

    # World-side access returns the owning Grid, so samples can be edited.
    world.resources.get[Grid]().values[3] = 5
    context.run[add_grid_sample]()
    assert_equal(world.storage.get[Int32](entity), 15)

    comptime if has_accelerator():
        context.run[add_grid_sample, on_device=True]()
        assert_equal(world.storage.get[Int32](entity), 20)
        assert_equal(world.resources.get[Grid]().values[3], 5)

```

The host calls always run; the device call runs when an accelerator is available.
No explicit binding registration or manual transfer is required. Editing the
owner between runs changes what the next invocation sees. Kernel results go to
components; the read-only resource is never downloaded or changed by the kernel.
Host-only resources can continue implementing `ResourceType` without an adapter.

### Adapter allocation and access rules

Every adapter must support concurrent reads of its read view, `View[False]`, on
the view's execution target. View methods and all reachable memory must permit concurrent
reads without hidden unsafe mutation. No escaped alias may mutate, resize,
relocate, or free backing data before invocation completion; immutable pointer
fields alone do not establish this guarantee. This is a universal adapter
contract, with no capability marker.

Threaded host calls accept adapted sources only through explicit `read`
declarations. The caller validates and binds each source once, then shares the
same descriptor and sample storage across jobs. Resource leases and descriptor
owners remain alive until all workers join, including whole-range fallback.
Ordinary pointer-free read resources also work without an adapter. Ordinary
mutable resources remain unsupported by this engine; mutable adapted resources
require [concurrent mutation support](#mutable-adapted-resources-experimental).

Use nonnegative cache slots for sample allocations. Slot `-1` is reserved for
Larecs's view descriptor. For multiple arrays, give each array its own stable
slot, such as `0` for samples and `1` for coordinates. Each world keeps a separate
cache per source type, tied to its device context. Capacity is reused, and every
preparation uploads current contents. Adapters need no revision tracking of
their own: in worlds that [reuse device copies](#reusing-unchanged-device-copies-experimental),
Larecs skips `prepare_device` entirely while the source is unchanged.

The cache accepts supported pointer-free trivial sample
values, snapshots them in native owned staging, and returns an immutable device
pointer. Adapters must use cache-owned allocations and this upload helper;
queued copies from external host pointers or pointers to temporary allocations
violate the lifetime contract. Views may contain immutable pointers and trivial
metadata; mutable pointer fields are rejected. Adapters remain responsible for
valid device addresses and pointee interpretation.

There is no adapter factory or instance. Registration happens automatically on
`add` and insert-on-`set`; source types identify bindings, so two resources may
share the same view type. A wrapper can adapt a third-party owner. See the
[compiled grid example](../../design/research/resource-view-probe.mojo).

Adapters without mutation support accept only `read`, including on the host;
`Resources[AdaptedSource]()` and mutable declarations fail compilation.
`get[Source]()` always returns the associated view; kernels cannot access the
owner. Edit the world-side owner between runs, including whole-instance
assignment through `world.resources.get[T]() = T(...)`; the next run validates
and uploads the new source without rebinding. Copied worlds have independent host
owners and empty resource caches.

## Mutable adapted resources (experimental)

An adapter can also give kernels a **writer view**, so shared output such as a
per-cell grid is filled without a `MutCapture` and with the same kernel on
every target. The access declaration selects the view:

| Declaration | `get[T]()` returns | Output before the kernel runs |
| --- | --- | --- |
| `Resources().read[T]()` | `T.View[False]` | Not applicable |
| `Resources().write[T]()` | `T.View[True]` | Fresh, initialized by the adapter |
| `Resources().read_write[T]()` | `T.View[True]` | Existing contents preserved |

Read and writer views can be different types:

```mojo
struct GridAdapter(ResourceAdapter):
    comptime Source = Grid
    comptime View[mutable: Bool] = GridFill if mutable else GridRead
    comptime supports_mutation = True
    comptime supports_concurrent_mutation = True
```

Both capabilities default to `False`. `supports_mutation` admits `write` and
`read_write` declarations for sequential host runs. Device and `threaded=True`
runs also require `supports_concurrent_mutation`. Declare it only if every
writer-view operation is safe under concurrent use, for example because slots
are reserved with [atomics](../synchronization) and then written disjointly.
Larecs leases the source exclusively for the invocation. This does not prevent
races between the GPU threads or host workers of one kernel: **you are
responsible for safe resource access.** Unsupported combinations fail
compilation.

The descriptor a kernel receives is immutable. A writer view holds pointers to
adapter-managed backing buffers, such as slots, per-cell counters, reductions,
and error flags, and mutates them through its own methods. Mutable adapters
implement four hooks that receive the full `ResourceAccess` mode, so `write`
can initialize fresh output while `read_write` preserves it:

| Hook | When Larecs calls it |
| --- | --- |
| `bind_host_mutable[access](mut source)` | Once before host kernels run. On the host, kernels write the source's buffers directly. Also called for device runs without matching rows. |
| `prepare_device_mutable[access](mut source, mut cache)` | Once before a device launch. Use `cache.fill` for fresh output and `cache.upload_mutable` to preserve contents. |
| `stage_device_results[access](mut source, mut cache)` | After the launch is queued. Stage every output with `cache.download`. |
| `finalize[access](mut source)` | Once after all kernel work completed and device outputs were published. Use it to clamp counters or report overflow. |

Preparation and finalization run once per invocation, across every matching
archetype, selected range, threaded chunk, and device launch, including runs
with no matching rows. Output is never reset per archetype or worker. Device
runs use the world's device queue and cache; buffers and staging stay alive
until completion. Mutable adapted sources are prepared on every run, even in
worlds that [reuse device copies](#reusing-unchanged-device-copies-experimental).
Size host targets before staging downloads; they are written only after the
queue completes.

Failures follow the [invocation rules](#invocation-lifetime-and-failures):

- Host writes are not rolled back. If preparation fails after `write`
  initialization, the source stays initialized, and `finalize` does not run.
- Device outputs are published only after synchronization succeeds. A failed
  run discards them.
- If `finalize` raises, the run raises, but published outputs remain and the
  world stays usable.

[`examples/scatter_resource.mojo`](../../../examples/scatter_resource.mojo)
is a complete example. Writers reserve per-cell slots with atomic counters
and count dropped writes; `finalize` clamps the counters. The same thin kernel
runs sequentially, threaded, and on a device. Run it with
`pixi run scatter-example`. Slot order within a cell depends on scheduling.

### Migrating existing adapters

Adapters written for the read-only API need three changes:

1. Replace `comptime View = MyView` with `comptime View[mut: Bool] = MyView`.
2. Change `bind_host` and `prepare_device` to return `Self.View[False]`.
3. Remove `comptime KernelView = MyView` from the source. `KernelView` still
   exists as an alias for `View[False]`.

Adapters that do not opt into mutation keep their behavior. Mutable
declarations of them now fail with "mutable access requires
Adapter.supports_mutation".

## Invocation lifetime and failures

`run` completes synchronously. Larecs retains sources and descriptors throughout
execution, rejects reentrant lookup/replacement/removal of bound sources, and
rejects duplicate source declarations. Previously escaped `UnsafeAnyOrigin`
references must not mutate or resize the source while a kernel uses its view;
views and references must not escape the invocation. Copying or destroying leased
storage through an escaped alias aborts because lifecycle operations cannot raise.

Device component, capture, and resource downloads use owned staging and publish
only after synchronization succeeds. On failure Larecs drains the queue and
propagates the error; if completion remains unknown, further execution on the
world raises. Failed calls discard staged outputs, without promising rollback of
other host effects. Empty device matches still validate resources and adapters
but perform no device allocation, upload, or launch.

## Reusing unchanged device copies (experimental)

By default every `on_device=True` run uploads all resources and readable
component columns it declares, even if they did not change. Worlds that call
`world.reuse_device_copies(True)` skip uploads of data that is unchanged since
its device copy was made. For adapted resources this skips the whole
`prepare_device` call; validation and leases still run on every call. Written
data is still downloaded after every run.

Larecs cannot see what you do with a reference after it returns it. It tracks
revisions that advance on every Larecs access that *may* mutate data:

- Resources: `add`, `set`, `get` through a mutable world, host runs declaring
  `write` or `read_write`, and device runs writing the resource.
- Component columns, per type and physical store: `world.storage.get` and
  `set`, kernel runs writing the type, and every structural change, spatial
  reordering, or partition move of the store.

Use `world.resources.read[T]()` and `world.storage.read[T](entity)` for reads
between device runs: they return immutable references and keep device copies
reusable, whereas `get` on a mutable world always counts as a mutation. Read
queries never count as mutations.

Component columns are reused per contiguous store range. Kernels with
different filters on the same component type pack stores at different
offsets, so alternating them uploads that column again each time.

> **Re-obtain or invalidate.** In a world that reuses device copies, never
> mutate a resource through a reference obtained before a later Larecs call or
> through a raw pointer without telling Larecs. Re-obtain the reference with
> `get` after each run, or call `world.resources.invalidate_device[T]()` (or
> `world.invalidate_device_copies()` for everything) after the mutation.
> Otherwise the next device run silently reads the stale device copy.

```mojo {doctest="guide_resources" global=true}
    world.reuse_device_copies(True)
    # Reading through `read` keeps an unchanged device copy reusable.
    _ = world.resources.read[Time]().time
    # A pointer kept across runs bypasses revision tracking...
    var time_ptr = Pointer(to=world.resources.get[Time]())
    time_ptr[].time = 4.0
    # ...so invalidate after mutating through it.
    world.resources.invalidate_device[Time]()
    world.reuse_device_copies(False)
```

A failed device run marks the copies it touched as unknown, so the next run
uploads them again. Disabling reuse, removing a resource, and copying the world
discard device copy records.

## Removing resources

One or multiple resources can be removed via the
{{< api ResourceStorage.remove remove >}} method. The existence
of a resource is checked via the {{< api ResourceStorage.has has >}} method.

When removing multiple types, removals happen in argument order. If a later
type is missing, `remove` raises after any earlier types have already been
removed. Check all types with `has` first when the operation must be
all-or-nothing.

```mojo {doctest="guide_resources" global=true}
    # Remove the `Time` and the `Temperature` resource
    world.resources.remove[Time, Temperature]()

    # Check if the `Time` resource exists
    assert_false(world.resources.has[Time]())

    # `set[add_if_not_found=True]` can insert it again
    world.resources.set[add_if_not_found=True](Time(4.0))
    assert_true(world.resources.has[Time]())
```
