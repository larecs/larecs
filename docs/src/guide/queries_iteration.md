+++
type = "docs"
title = "Queries and iteration"
weight = 40
+++

Iterating over entities can be done via
classic `for` loops applied to [queries](#queries),
or via an [`apply`](#applying-functions-to-entities-in-queries)
operation, which applies a given function to all entities
conforming to a query.

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
from larecs import World, Entity, Filter, MutArchetypeRowAccessor
from std.testing import *

@fieldwise_init
struct Position(Copyable, Movable):
    var x: Float64
    var y: Float64

@fieldwise_init
struct Velocity(Copyable, Movable):
    var dx: Float64
    var dy: Float64
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
    # Calling `query` immediately locks the storage; see
    # "Preventing iterator invalidation" below.
    var query = world.storage.query[Filter().include[Position]()]()

    # Of the entities we have just added,
    # two have a position component
    print(len(query)) # "2"

    # Query iterators are copyable. A copy starts at the same position and
    # acquires its own structural-change lock.
    var query_copy = query.copy()

    # Now let us iterate over the queried entities
    # (`^` transfers this iterator into the loop without copying it).
    for entity in query^:
        ref pos = entity.get[Position]()
        print(
            "Entity at position: ("
            + String(pos.x) + ", " + String(pos.y) + ")"
        )

    # The copy has an independent cursor and lock, so it can be consumed
    # separately and remains valid after the original iterator is destroyed.
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
way, not written -- see
[Preventing iterator invalidation](#preventing-iterator-invalidation-the-locked-world)
below for how to mutate them.

Because a query's filter guarantees which components every matching
entity has, {{< api ArchetypeRowAccessor.get get >}} checks its
component type against that filter at *compile time*: requesting a
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

## Preventing iterator invalidation: the locked world

Adding/removing entities to/from the world
or components to/from entities
while iterating could invalidate the iterator. That is,
the iterator could leave out some entities or consider
some entities multiple times.
To prevent this, Larecs🌲 locks the storage during iterations.
This means that methods that change how many entities
exist in the world or which components entities have
will raise exceptions if called during iteration.

Queries and batch operations return a `LockedWorldEntityIterator`. This wrapper
owns both the internal, lock-free `_WorldEntityIterator` and a
structural-change lock acquired for its lifetime, and it forwards iteration
(`next`, `len`, `bool`) straight to the wrapped iterator while holding that
lock—there is no separate accessor to unwrap. The lock stays held for the
wrapper's lifetime, including between calls to `next`, `len`, and `bool`, and
is released on destruction—even when a loop exits early. Moving the wrapper
transfers the existing lock; exhausting the iterator does not unlock it while
the wrapper remains alive.

Locked iterators are copyable. Calling `copy()` preserves the iterator's
current traversal position and acquires a distinct structural-change lock for
the copy. Each iterator releases only its own lock, so destroying or consuming
one copy does not unlock the storage while another copy remains alive. Because
Mojo's `Copyable` interface cannot return an error, copying aborts if the
storage's lock capacity is exhausted. Moving an iterator with `^` remains the
way to transfer it without acquiring another lock.

These locks are not thread mutexes; they only prevent structural changes.
Component values reached through this iterator are themselves read-only --
mutate components from inside a system instead, via {{< api SystemContext.run >}}
(see [Systems and the scheduler](../systems_scheduler)).

```mojo {doctest="guide_queries_iteration" global=true}
    for entity in world.storage.query[Filter().include[Position]()]():

        # Adding entities to the world while iterating
        # is forbidden.
        with assert_raises():
            _ = world.storage.add_entity(Velocity(1, 0)) # Raises an exception

        # Changing components of an entity while iterating
        # is forbidden.
        with assert_raises():
            world.storage.add(entity.get_entity(), Velocity(2, 3)) # Raises an exception
```

If we want to add or remove components from entities while iterating,
we need to store the entities in an intermediate
container and iterate over them in
a separate loop. Consider the following example, where we
add a `Velocity` component to all entities that have a `Position`
but no `Velocity` component:

```mojo {doctest="guide_queries_iteration" global=true}
    # A container for the entities
    var entities = List[Entity]()
    for entity in world.storage.query[
        Filter().include[Position].exclude[Velocity]()
    ]():

        # Store the entity for later use
        entities.append(entity.get_entity())

    # Add a velocity component to all stored entities
    for entity in entities:
        # We can add components to the entity
        # because we are not iterating over the storage
        world.storage.add(entity, Velocity(1, 0))
```

> [!Note]
> As shown [earlier](../adding_and_removing_entities#batch-addition),
> adding a component to entities matched by a query directly (without an
> intermediate container) is also possible and more efficient -- as long
> as the query excludes entities that already have the component being
> added.

## Applying functions to entities in queries

We may want to apply a certain operation to all entities
that have certain components. This can be achieved with
the {{< api HostStorage.apply apply >}} method. This method
iterates over all entities matching a filter and
calls the provided function with the entities as arguments.
The function must take a {{< api MutArchetypeRowAccessor >}}
as its only argument. Applying a function to all entities
can be more convenient than iterating over the entities
manually.

For example, if we want to apply a function that moves all entities
with a `Position` and a `Velocity` component, we can do this as follows:

```mojo {doctest="guide_queries_iteration" global=true}
    # Define the move operation
    def move(accessor: MutArchetypeRowAccessor) raises:
        ref move_pos = accessor.unsafe_get[Position]()
        ref move_vel = accessor.unsafe_get[Velocity]()
        move_pos.x += move_vel.dx
        move_pos.y += move_vel.dy

    # Apply the move operation to all entities with a position and a velocity
    world.storage.apply(
        world.filter[Filter().include[Position, Velocity]()](),
        move,
    )
```

> [!Caution]
> The storage is locked during the iteration, just like during a normal
> query iteration. Do not attempt to add or remove entities or components
> from inside the operation.
