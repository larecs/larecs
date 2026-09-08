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
accessed and changed via the {{< api HostStorage.get get >}}
method of {{< api World World.storage >}}.

```mojo {doctest="guide_change_entities" global=true hide=true}
from larecs import World, Entity, Filter
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

```mojo {doctest="guide_change_entities" global=true hide=true}
def main() raises:
    var world = World[Position, Velocity]()
```

A reference to a component can be obtained
as follows:

```mojo {doctest="guide_change_entities" global=true}
    # Add an entity with a component
    var entity = world.storage.add_entity(Position(0, 0))

    # Get a reference to the position;
    ref pos = world.storage.get[Position](entity)

    # We can change the reference.
    pos.x = 5
    assert_equal(world.storage.get[Position](entity).x, 5)

    # We can also replace the component completely.
    world.storage.get[Position](entity) = Position(10, 0)
    assert_equal(world.storage.get[Position](entity).x, 10)
```

Of course, accessing a component only works if the entity has
the component in question. Accessing a component
that the entity does not have will result in an error.

```mojo {doctest="guide_change_entities" global=true}
    # Add an entity without a velocity component
    entity = world.storage.add_entity(Position(0, 0))

    with assert_raises():
        # This will result in an error
        _ = world.storage.get[Velocity](entity)
```

We can check if an entity has a component using the
{{< api HostStorage.has has >}} method.

```mojo {doctest="guide_change_entities" global=true}
    # Check if the entity has a velocity component
    if world.storage.has[Velocity](entity):
        print("Entity has a velocity component")
    else:
        print("Entity does not have a velocity component")
```

## Setting multiple components at once

We can set the values of multiple components at once
using the {{< api HostStorage.set set >}}
method. This method takes an arbitrary number of
components and sets them all in one go.

```mojo {doctest="guide_change_entities" global=true}
    # Add an entity with two components
    entity = world.storage.add_entity(Position(0, 0), Velocity(1, 1))

    # Set multiple components at once
    world.storage.set(entity, Position(5, 5), Velocity(2, 2))
```

## Adding and removing components

Components can be added and removed from entities using the
{{< api HostStorage.add add >}} and {{< api HostStorage.remove remove >}} methods.

```mojo {doctest="guide_change_entities" global=true}
    # Add an entity without components
    entity = world.storage.add_entity()

    # Add components to the entity
    world.storage.add(entity, Position(0, 0), Velocity(1, 1))

    # Remove a component from the entity
    world.storage.remove[Velocity](entity)
```

This works with arbitrary numbers of components, so we can add or remove
any number of components at once.

If we want to remove some components and replace
them with other components directly, we can use the
{{< api HostStorage.replace replace >}} method in combination with the
{{< api Replacer.by by >}} method. The `replace` method takes
Components to be removed as parameters, whereas the `by` method
takes the new components to be added.

```mojo {doctest="guide_change_entities" global=true}
    # Replace the position component with a velocity component
    world.storage.replace[Position]().by(Velocity(2, 2), entity=entity)
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
{{< api HostStorage.add add >}} method with a query:

```mojo {doctest="guide_change_entities" global=true}
    # Add 10 entities with only Position components
    _ = world.storage.add_entities(Position(0, 0), count=10)

    # Add a Velocity component to all entities that have Position but not Velocity
    for entity in world.storage.add(
        world.filter[Filter().include[Position].exclude[Velocity]()](),
        Velocity(1.0, 0.5),
    ):
        ref pos = entity.unsafe_get[Position]()
        ref vel = entity.unsafe_get[Velocity]()
```

This is significantly more efficient than adding components to entities one by one:

```mojo {doctest="guide_change_entities" global=true}
    # Less efficient approach (avoid this for large numbers of entities)
    var entities = List[Entity]()
    for entity in world.storage.query[
        Filter().include[Position].exclude[Velocity]()
    ]():
        entities.append(entity.get_entity())
```

Similar methods exist also for {{< api HostStorage.remove removing >}} and
{{< api HostStorage.replace replacing >}} components from multiple entities at once.

```mojo {doctest="guide_change_entities" global=true}
    # Add 10 more entities with Position and Velocity components
    _ = world.storage.add_entities(Position(0, 0), Velocity(1.0, 1.0), count=10)

    # Remove the Velocity component from all entities that have both Position and Velocity
    for entity in world.storage.remove[Velocity](
        world.filter[Filter().include[Position, Velocity]()]()
    ):
        ref pos = entity.unsafe_get[Position]()
```

For batch replace operations, you also need to use the {{< api Replacer.by by >}} helper method to specify which
components should be used as replacement.

```mojo {doctest="guide_change_entities" global=true}
    # Add 10 more entities with only a Position component
    _ = world.storage.add_entities(Position(0, 0), count=10)

    # Replace Position with Velocity for all entities that have only a Position
    for entity in world.storage.replace[Position]().by(
        Velocity(2.0, 2.0),
        filter=world.filter[Filter().include[Position].exclusive()](),
    ):
        ref vel = entity.unsafe_get[Velocity]()
```

> [!Important]
> The query must ensure that all matching entities have the components you want to remove;
> otherwise an error will be raised.
