+++
type = "docs"
title = "Queries and iteration"
weight = 40
+++

Iterating over entities can be done via
classic `for` loops applied to [queries](#queries). Queries provide
read-only access to their results. In application logic, systems are the
principal place for mutations; use a
[kernel](#processing-components-with-kernels) to update components across all
entities matching a filter.

## Queries

The {{< api HostStorage.query query >}} method of
{{< api HostStorage >}} allows to iterate over all
entities with or without a specific
set of components. It takes a compile-time {{< api Filter >}}
specifying the components that each entity we look for must have
(and, optionally, must not have). For example, if we want to
iterate over all entities with a `Position` and a `Velocity` component,
we can do this as follows:

```mojo {doctest="guide_queries_iteration" global=true hide=true}
from larecs import World, Filter, SystemContext, KernelContext

@fieldwise_init
struct Position(Copyable, Movable):
    var x: Float64
    var y: Float64

@fieldwise_init
struct Velocity(Copyable, Movable):
    var dx: Float64
    var dy: Float64

comptime move_filter = Filter().include[Position].read[Velocity]()

def move_entities(context: KernelContext[move_filter]):
    for entity in context:
        ref pos = entity.get[Position]()
        ref vel = entity.get[Velocity]()
        pos.x += vel.dx
        pos.y += vel.dy
```

```mojo {doctest="guide_queries_iteration" global=true hide=true}
def main() raises:
    var world = World[Position, Velocity]()
```

```mojo {doctest="guide_queries_iteration" global=true}
    # Add entities with different components
    _ = world.storage.add_entity()
    _ = world.storage.add_entity(Position(0, 0))
    _ = world.storage.add_entity(Velocity(1, 0))
    _ = world.storage.add_entity(Position(1, 0), Velocity(1, 0))

    # Query all entities that have a position.
    var query = world.storage.query[Filter().include[Position]()]()

    # Of the entities we have just added,
    # two have a position component
    print(len(query)) # "2"

    # Query iterators are copyable. A copy starts at the same position.
    var query_copy = query.copy()

    # Now let us iterate over the queried entities
    # (`^` transfers this iterator into the loop without copying it).
    for entity in query^:
        ref pos = entity.get[Position]()
        print(
            "Entity at position: ("
            + String(pos.x) + ", " + String(pos.y) + ")"
        )

    # The copy has an independent cursor, so it can be consumed separately.
    for _ in query_copy^:
        pass
```

The filter can also exclude entities that have
certain components. For example, if we want to iterate
over all entities that have a `Position` component
but not a `Velocity` component, we can do this
using {{< api Filter.exclude exclude >}}:

```mojo {doctest="guide_queries_iteration" global=true}
    var excluding_query = world.storage.query[
        Filter().include[Position].exclude[Velocity]()
    ]()
    print(len(excluding_query)) # "1"
```

Furthermore, we can also query for entities that have
exactly the components we are looking for but no more.
This can be done using {{< api Filter.exclusive exclusive >}}.
For example, if we want to iterate
over all entities that have only a `Position` component,
we can do this as follows:

```mojo {doctest="guide_queries_iteration" global=true}
    var exclusive_query = world.storage.query[
        Filter().include[Position].exclusive()
    ]()
    print(len(exclusive_query)) # "1"
```

> [!Note]
> Determining the length of a query is not a trivial operation
> and may require an internal iteration if the ECS involves many components.
> Therefore, it is advisable to avoid applying the `len` function
> to queries in "hot" code. Nonetheless, the `len` function
> is much faster than counting entities manually by iterating over a query.

## Iterating over queries

As we have seen, we can iterate over queries using a for loop.
Here, the control variable ("entity") is an {{< api ArchetypeRowAccessor >}}
object, i.e., not technically an {{< api Entity >}}, which is
merely an identifier of an entity. Instead, the `ArchetypeRowAccessor`
directly provides methods to get and check the existence
of components, so that we do not need to call the storage's
methods for this, making the code more efficient. Since `query`'s
iterator gives read-only access, components can only be read this
way, not written. Use a [kernel](#processing-components-with-kernels) from a
system to mutate matching components.

Because a query's filter guarantees which components every matching
entity has, {{< api ArchetypeRowAccessor.get get >}} checks its
component type against that filter at _compile time_: requesting a
component the filter didn't include is a compile error, not a runtime
one. For a component the filter doesn't guarantee -- typically one
you only conditionally access after checking
{{< api ArchetypeRowAccessor.has has >}} -- use
{{< api ArchetypeRowAccessor.unsafe_get unsafe_get >}} instead, which
checks at runtime and raises if the component is missing.

```mojo {doctest="guide_queries_iteration" global=true}
    for entity in world.storage.query[Filter().include[Position]()]():
        ref pos = entity.get[Position]()
        print(
            "Entity at position: ("
            + String(pos.x) + ", " + String(pos.y) + ")"
        )
        if entity.has[Velocity]():
            # `Velocity` isn't included by this query's filter, so it isn't
            # guaranteed to exist on every matching entity -- `get` would be
            # a compile error here. `unsafe_get` is the checked-at-runtime
            # escape hatch for exactly this case.
            ref vel = entity.unsafe_get[Velocity]()
            # Also print the velocity
            print(
                " - with velocity ("
                + String(vel.dx) + ", " + String(vel.dy) + ")"
            )
```

> [!Note]
> The `ArchetypeRowAccessor` is a temporary object that is
> created for each iteration. Therefore, it should not be
> stored in a container. Use {{< api ArchetypeRowAccessor.get_entity >}}
> instead if you need to store the entity for later use.

## Processing components with kernels

A kernel is a component-processing function passed to
{{< api SystemContext.run >}}. It receives a {{< api KernelContext >}} and
iterates over the entities matching its filter. The filter declares which
components the kernel can write and which it can only read. The same kernel
can run on the CPU or, for supported component types, a GPU accelerator.

The `move_entities` kernel declared above writes `Position` and only reads
`Velocity`. The following direct construction demonstrates how the context
invokes it:

```mojo {doctest="guide_queries_iteration" global=true}
    var context = SystemContext(world)
    context.run[move_entities]()
```

In an application, the scheduler supplies this context to each system's
lifecycle methods, and the system calls `run` from there. The system is the
scheduled unit of application logic; the kernel is the function it delegates
filtered component processing to. See
[Systems and the scheduler](../systems_scheduler) for the complete pattern.
