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
GPU kernel path described below; host-only resources do not need that trait.

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
loop: the CPU calls the kernel once per matching archetype, while the GPU
processes all matching rows in one launch.

Kernels that access resources must be non-capturing functions and use the
`context.run[kernel]()` form shown above. The capturing-closure overload,
`context.run(kernel)`, does not currently support required resources.

To run this same kernel on a GPU, replace its CPU `run` call with:

```mojo
    context.run[move_with_time, on_gpu=True]()
```

For GPU execution, every accessed component and required resource must conform
to `TrivialRegisterPassable`. Larecs transfers the declared resources to the
device before execution and copies them back afterward, including any kernel
changes. Resources with heap allocations or other non-trivial state, such as
`SelectedEntities`, can be used on the host but cannot be passed to a GPU
kernel.

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
