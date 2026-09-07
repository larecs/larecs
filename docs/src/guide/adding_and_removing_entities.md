+++
type = "docs"
title = "Adding and removing entities"
weight = 20
+++

Adding and removing individual entities is done
via the {{< api HostStorage.add_entity add_entity >}}
and {{< api HostStorage.remove_entity remove_entity >}}
methods of {{< api World World.storage >}}.
Revisiting our earlier example of a world with `Position` and
`Velocity`, this reads as follows:

```mojo {doctest="guide_add_remove_entities" global=true hide=true}
from larecs import World, Filter

@fieldwise_init
struct Position(Copyable, Movable):
    var x: Float64
    var y: Float64

@fieldwise_init
struct Velocity(Copyable, Movable):
    var dx: Float64
    var dy: Float64
```

```mojo {doctest="guide_add_remove_entities" global=true hide=true}
def main() raises:
    var world = World[Position, Velocity]()
```

```mojo {doctest="guide_add_remove_entities" global=true}
    # Add an entity and get its representation
    var entity = world.storage.add_entity()

    # Remove the entity
    world.storage.remove_entity(entity)
```

Components can be added to the entities directly
upon creation. For example, to create an entity
with a position at (0, 0) and a velocity of (1, 0),
we can do the following:

```mojo {doctest="guide_add_remove_entities" global=true}
    entity = world.storage.add_entity(Position(0, 0), Velocity(1, 0))
```

## Batch addition

If we want to create multiple entities at once,
we can do this in a similar manner via {{< api HostStorage.add_entities add_entities >}}:

```mojo {doctest="guide_add_remove_entities" global=true}
    # Add a batch of 10 entities with given position and velocity
    _ = world.storage.add_entities(Position(0, 0), Velocity(1, 0), count=10)
```

In contrast to `add_entity`, which creates a single entity,
`add_entities` returns an iterator over all newly created
entities. Suppose, we want to place the entities all on
a line, each one unit apart from the other, we could do this
as follows:

```mojo {doctest="guide_add_remove_entities" global=true}
    # Add a batch of 10 entities with given position and velocity, placed on a line
    var x_position = 0.0
    for entity in world.storage.add_entities(Position(0, 0), Velocity(1, 0), count=10):
        entity.get[Position]().x = x_position
        x_position += 1
```

More information on manipulation of and iteration over entities
is provided in the upcoming chapters.

> [!Note]
> Iterators block structural changes to the world for their entire lifetime.
> They may be stored or copied, but every copy acquires and owns a distinct
> lock. Move an iterator into a loop with `^` when no independent copy is
> needed, and avoid keeping iterators alive longer than necessary.

## Batch removal

If we want to remove multiple entities at once,
we need to characterize which entities we mean. To that
end, we use queries, which characterize entities
by their components. For example, removing all
entities that have the component `Position`
can be done with {{< api HostStorage.remove_entities remove_entities >}} as follows:

```mojo {doctest="guide_add_remove_entities" global=true}
    # Remove all entities that have a Position component
    world.storage.remove_entities(world.filter[Filter().include[Position]()]())
```

More on queries can be found in the chapter [Queries and iteration](../queries_iteration).

> [!Tip]
> Adding and removing many components in one go is significantly
> more efficient than adding and removing components
> one by one.
