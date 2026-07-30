+++
type = "docs"
title = "Adding and removing entities"
weight = 20
+++

Adding and removing individual entities is done
via the {{< api World.add_entity add_entity >}}
and {{< api World.remove_entity remove_entity >}}
methods of {{< api World >}}.
Revisiting our earlier example of a world with `Position` and
`Velocity`, this reads as follows:

```mojo {doctest="guide_add_remove_entities" global=true hide=true}
from larecs import World

@fieldwise_init
struct Position(Copyable, Movable):
    var x: Float64
    var y: Float64

@fieldwise_init
struct Velocity(Copyable, Movable):
    var dx: Float64
    var dy: Float64
```

```mojo {doctest="guide_add_remove_entities" hide=true}
world = World[Position, Velocity]()
```

```mojo {doctest="guide_add_remove_entities"}
# Add an entity and get its representation
entity = world.add_entity()

# Remove the entity
world.remove_entity(entity)
```

Components can be added to the entities directly
upon creation. For example, to create an entity
with a position at (0, 0) and a velocity of (1, 0),
we can do the following:

```{doctest="guide_add_remove_entities"}
entity = world.add_entity(Position(0, 0), Velocity(1, 0))
```

## Batch addition

If we want to create multiple entities at once,
we can do this in a similar manner via {{< api World.add_entities add_entities >}}:

```mojo {doctest="guide_add_remove_entities"}
# Add a batch of 10 entities with given position and velocity
_ = world.add_entities(Position(0, 0), Velocity(1, 0), count=10)
```

In contrast to `add_entity`, which creates a single entity,
`add_entities` returns an iterator over all newly created
entities. Suppose, we want to place the entities all on
a line, each one unit apart from the other, we could do this
as follows:

```mojo {doctest="guide_add_remove_entities"}
# Add a batch of 10 entities with given position and velocity
x_position = 0
for entity in world.add_entities(Position(0, 0), Velocity(1, 0), count=10):
    entity.get[Position]().x = x_position
    x_position += 1
```

More information on manipulation of and iteration over entities
is provided in the upcoming chapters.

> [!Note]
> Iterators block certain changes to the world and should not
> be stored in a variable. That is, use the result of `add_entities`
> only in the right hand side of for loops.

## Batch removal

If we want to remove multiple entities at once,
we need to characterize which entities we mean. To that
end, we use queries, which characterize entities
by their components. For example, removing all
entities that have the component `Position`
can be done with {{< api World.remove_entities remove_entities >}} as follows:

```mojo {doctest="guide_add_remove_entities"}
# Add a batch of 10 entities with given position and velocity
world.storage.remove_entities(world.storage.query[Position]())
```

More on queries can be found in the chapter [Queries and iteration](../queries_iteration).

> [!Tip]
> Adding and removing many components in one go is significantly
> more efficient than adding and removing components
> one by one.
