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

{{< api Query Queries >}} allow to iterate over all
entities with or without a specific
set of components. To create a query, we can use
the {{< api Storage.query query >}} method of
{{< api Storage >}}. The parameters used in this method are the components
that each entity we look for must have. For example, if we want to
iterate over all entities with a `Position` and a `Velocity` component,
we can do this as follows:

```mojo {doctest="guide_queries_iteration" global=true hide=true}
from larecs import World, MutableEntityAccessor, Entity
from testing import *

@fieldwise_init
struct Position(Copyable, Movable):
    var x: Float64
    var y: Float64

@fieldwise_init
struct Velocity(Copyable, Movable):
    var dx: Float64
    var dy: Float64
```

```mojo {doctest="guide_queries_iteration" hide=true}
world = World[Position, Velocity]()
```

```mojo {doctest="guide_queries_iteration"}
# Add entities with different components
_ = world.add_entity()
_ = world.add_entity(Position(0, 0))
_ = world.add_entity(Velocity(1, 0))
_ = world.add_entity(Position(1, 0), Velocity(1, 0))

# Query all entities that have a position
query = world.storage.query[Position]()

# Of the entities we have just added,
# two have a position component
print(len(query)) # "2"

# Now let us iterate over the queried entities
for entity in query:
    ref pos = entity.get[Position]()
    print(
        "Entity at position: ("
        + String(pos.x) + ", " + String(pos.y) + ")"
    )
```

Queries can be adjusted to also exclude entities that have
certain components. For example, if we want to iterate
over all entities that have a `Position` component
but not a `Velocity` component, we can do this
using the {{< api Query.without without >}} method:

```mojo {doctest="guide_queries_iteration"}
excluding_query = world.storage.query[Position]().without[Velocity]()
print(len(excluding_query)) # "1"
```

Furthermore, we can also query for entities that have
exactly the components we are looking for but no more.
This can be done using the {{< api Query.exclusive exclusive >}}
method. For example, if we want to iterate
over all entities that have only a `Position` component,
we can do this as follows:

```mojo {doctest="guide_queries_iteration"}
excluding_query = world.storage.query[Position]().exclusive()
print(len(excluding_query)) # "1"
```

> [!Note]
> Determining the length of a query is not a trivial operation
> and may require an internal iteration if the ECS involves many components.
> Therefore, it is advisable to avoid applying the `len` function
> to queries in "hot" code. Nonetheless, the `len` function
> is much faster than counting entities manually by iterating over a query.

## Iterating over queries

As we have seen, we can iterate over queries using a for loop.
Here, the control variable ("entity") is an {{< api EntityAccessor >}}
object, i.e., not technically an {{< api Entity >}}, which is
merely an identifier of an entity. Instead, the `EntityAccessor`
directly provides methods to get, set, and check the existence
of components, so that we do not need to call the world's
methods for this, making the code more efficient.

```mojo {doctest="guide_queries_iteration"}
for entity in world.storage.query[Position]():
    ref pos = entity.get[Position]()
    print(
        "Entity at position: ("
        + String(pos.x) + ", " + String(pos.y) + ")"
    )
    if entity.has[Velocity]():
        ref vel = entity.get[Velocity]()
        # Also print the velocity
        print(
            " - with velocity ("
            + String(vel.dx) + ", " + String(vel.dy) + ")"
        )
```

> [!Note]
> The `EntityAccessor` is a temporary object that is
> created for each iteration. Therefore, it should not be
> stored in a container. Use {{< api EntityAccessor.get_entity >}}
> instead if you need to store the entity for later use.

> [!Note]
> The `EntityAccessor` can be implicitly
> converted to an `Entity` object and hence be used
> wherever an `Entity` is required.

## Preventing iterator invalidation: the locked world

Adding/removing entities to/from the world
or components to/from entities
while iterating could invalidate the iterator. That is,
the iterator could leave out some entities or consider
some entities multiple times.
To prevent this, Larecs🌲 locks the world during iterations.
This means that methods that change how many entities
exist in the world or which components entities have
will raise exceptions if called during iteration.

```mojo {doctest="guide_queries_iteration"}
for entity in world.storage.query[Position]():

    # Adding entities to the world while iterating
    # is forbidden.
    with assert_raises():
        _ = world.add_entity(Velocity(1, 0)) # Raises an exception

    # Changing components of an entity while iterating
    # is forbidden.
    with assert_raises():
        _ = world.add(entity, Position(1, 2)) # Raises an exception
```

If we want to add or remove components from entities while iterating,
we need to store the entities in an intermediate
container and iterate over them in
a separate loop. Consider the following example, where we
add a `Velocity` component to all entities that have a `Position`
but no `Velocity` component:

```mojo {doctest="guide_queries_iteration"}
# A container for the entities
entities = List[Entity]()
for entity in world.storage.query[Position]().without[Velocity]():

    # Store the entity for later use
    # The implicit conversion to `Entity`
    # allows us to use `entity` directly
    entities.append(entity)

# Add a velocity component to all stored entities
for entity in entities:
    # We can add components to the entity
    # because we are not iterating over the world
    _ = world.add(entity, Velocity(1, 0))
```

> [!Note]
> In a later release, Larecs🌲 will provide
> a batched version of the `add` and `remove` methods
> that will allow adding or removing components
> from multiple entities at once.

## Applying functions to entities in queries

We may want to apply a certain operation to all entities
that have certain components. This can be achieved with
the {{< api World.apply apply >}} method. This method
iterates over all entities conforming to a query and
calls the provided function with the entities as arguments.
The function must take a `MutableEntityAccessor`
(an alias for {{< api EntityAccessor `EntityAccessor[True]` >}})
as its only argument. Applying a function to all entities
can be more convenient and also faster than iterating over the entities
manually, especially if the function is vectorized, as is shown
in the [vectorization](../vectorization) chapter.

For example, if we want to apply a function that moves all entities
with a `Position` and a `Velocity` component, we can do this as follows:

```mojo {doctest="guide_queries_iteration"}
# Define the move function
fn move(entity: MutableEntityAccessor) capturing:
    try:
        ref move_pos = entity.get[Position]()
        ref move_vel = entity.get[Velocity]()
        move_pos.x += move_vel.dx
        move_pos.y += move_vel.dy
    except:
        # We could do proper error handling here
        # but for now, we just ignore the error
        pass

# Apply the move function to all entities with a position and a velocity
world.apply[move](world.storage.query[Position, Velocity]())
```

> [!Note]
> Currently, the applied operation can not raise exceptions.
> Therefore, we need to catch exceptions in the function
> itself. This is due to current limitations of Mojo and
> will be changed as soon as possible.

> [!Caution]
> The world is locked during the iteration, and
> accessing variables outside a locally defined
> function is an immature feature in Mojo. Do not
> attempt to access the `world` from inside the operation.
