+++
type = "docs"
title = "Changing entities"
weight = 30
+++

Entities may be changed by altering the values / attributes
of their components, adding new components, or removing
existing components.

## Accessing and changing individual components

The values of an entity's component can be
accessed and changed via the {{< api World.get get >}}
method of world.

```mojo {doctest="guide_change_entities" global=true hide=true}
from larecs import World
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

```mojo {doctest="guide_change_entities" hide=true}
world = World[Position, Velocity]()
```

A reference to a component can be obtained
as follows:

```mojo {doctest="guide_change_entities"}
# Add an entity with a component
entity = world.add_entity(Position(0, 0))

# Get a reference to the position;
ref pos = world.get[Position](entity)

# We can change the reference.
pos.x = 5
assert_equal(world.get[Position](entity).x, 5)

# We can also replace the component completely.
world.get[Position](entity) = Position(10, 0)
assert_equal(world.get[Position](entity).x, 10)
```

Of course, accessing a component only works if the entity has
the component in question. Accessing a component
that the entity does not have will result in an error.

```mojo {doctest="guide_change_entities"}
# Add an entity without a velocity component
entity = world.add_entity(Position(0, 0))

with assert_raises():
    # This will result in an error
    _ = world.get[Velocity](entity)
```

We can check if an entity has a component using the
{{< api World.has has >}} method.

```mojo {doctest="guide_change_entities"}
# Check if the entity has a velocity component
if world.has[Velocity](entity):
    print("Entity has a velocity component")
else:
    print("Entity does not have a velocity component")
```

## Setting multiple components at once

We can set the values of multiple components at once
using the {{< api World.set set >}}
method. This method takes an arbitrary number of
components and sets them all in one go.

```mojo {doctest="guide_change_entities"}
# Add an entity with two components
entity = world.add_entity(Position(0, 0), Velocity(1, 1))

# Set multiple components at once
world.set(entity, Position(5, 5), Velocity(2, 2))
```

## Adding and removing components

Components can be added and removed from entities using the
{{< api World.add add >}} and {{< api World.remove remove >}} methods.

```mojo {doctest="guide_change_entities"}
# Add an entity without components
entity = world.add_entity()

# Add components to the entity
world.add(entity, Position(0, 0), Velocity(1, 1))

# Remove a component from the entity
world.remove[Velocity](entity)
```

This works with arbitrary numbers of components, so we can add or remove
any number of components at once.

If we want to remove some components and replace
them with other components directly, we can use the
{{< api World.replace replace >}} method in combination with the
{{< api Replacer.by by >}} method. The `replace` method takes
Components to be removed as parameters, whereas the `by` method
takes the new components to be added.

```mojo {doctest="guide_change_entities"}
# Replace the position component with a velocity component
world.replace[Position]().by(Velocity(2, 2), entity=entity)
```

Similar to the `add` and `remove`
methods, this works with arbitrary numbers of
components, so we can replace any number of components with
any other number of new components.

> [!Tip]
> Replacing components in one go is significantly
> more efficient than removing and adding components separately.

### Batch operations

Sometimes you need to add or remove components from multiple entities at once.
Larecs🌲 provides batch operations that are more efficient than performing
individual operations on each entity.

> [!Tip]
> Batch operations are significantly more efficient than individual operations
> when working with large numbers of entities, as they minimize memory
> reorganization and improve cache locality.

You can add components to multiple entities that match a query using the
{{< api World.add add >}} method with a query:

```mojo {doctest="guide_change_entities"}
# Add 10 entities with only Position components
_ = world.add_entities(Position(0, 0), count=10)

# Add Velocity component to all entities that have Position but not Velocity
world.storage.add(
    world.storage.query[Position]().without[Velocity](),
    Velocity(1.0, 0.5)
)

# You can also add multiple components at once to multiple entities
world.storage.add(
    world.storage.query[Position]().without[Velocity](),
    Velocity(2.0, 1.0),
    # Additional components can be added here
)
```

This is significantly more efficient than adding components to entities one by one:

```mojo {doctest="guide_change_entities"}
# Less efficient approach (avoid this for large numbers of entities)
entities = List[Entity]()
for entity in world.storage.query[Position]().without[Velocity]():
    entities.append(entity)
```

Similar methods exist also for {{< api World.remove removing >}} and
{{< api World.replace replacing >}} components from multiple entities at once.

```mojo {doctest="guide_change_entities"}
# Add 10 entities with Position and Velocity components
_ = world.add_entities(Position(0, 0), Velocity(1.0, 1.0), count=10)

# Remove Velocity component from all entities that have both Position and Velocity
world.storage.remove[Velocity](
    world.storage.query[Position, Velocity]()
)

# You can also remove multiple components at once from multiple entities
world.storage.remove[Position, Velocity](
    world.storage.query[Position, Velocity]()
)
```

For batch replace operations, you also need to use the {{< api Replacer.by by >}} helper method to specify which
components should be used as replacement.

```mojo {doctest="guide_change_entities"}
# Add 10 entities with Position components
_ = world.add_entities(Position(0, 0), count=10)

# Replace Position with Velocity for all entities that have Position
world.storage.replace[Position]().by(
    Velocity(2.0, 2.0)
    query=world.storage.query[Position](),
)

# You can also replace multiple components with multiple other components
world.storage.replace[Position, Velocity]().by(
    world.storage.query[Position, Velocity](),
    Direction(0.0, 5.0),
    Acceleration(0.2, 0.4)
)
```

> [!Important]
> The query must ensure that all matching entities have the components you want to remove;
> otherwise an error will be raised.
