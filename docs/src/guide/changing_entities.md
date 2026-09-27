+++
type = "docs"
title = "Changing entities"
weight = 30
+++

Entities may be changed by altering the values / attributes
of their components, adding new components, or removing
existing components.

This chapter uses the `World` API directly to demonstrate each operation. In
application logic, [systems](../systems_scheduler) are the principal place for
these state changes. A system can access an individual entity through its
`SystemContext`, while updates over all entities matching a filter belong in
a [kernel](../queries_iteration#processing-components-with-kernels).

## Accessing and changing individual components

The values of an entity's component can be
accessed and changed via the {{< api HostStorage.get get >}}
method of {{< api World World.storage >}}.

```mojo {doctest="guide_change_entities" global=true hide=true}
from larecs import World, Entity, Filter, Components, SystemContext
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

Use {{< api SystemContext.add add >}}, {{< api SystemContext.remove remove >}},
and {{< api SystemContext.replace replace >}} for filtered batch changes.
Each returns a locked selection containing only rows actually modified:

```mojo {doctest="guide_change_entities" global=true}
    var context = SystemContext(world)
    var created = context.add_entities(Position(0, 0), count=10)
    created.add[
        Velocity, filter=Filter().include[Position].exclude[Velocity]()
    ](Velocity(1.0, 0.5))
```

An omitted selection-operation filter means no restriction beyond the saved
membership. A supplied filter is intersected with that membership; skipped
rows are unchanged and leave the selection's updated membership. Kernel filter
mismatches simply skip rows, but invalid component requests still raise.

```mojo {doctest="guide_change_entities" global=true}
    created.remove[Velocity]()
```

Selection replacement uses a compile-time `Components` list for removed types;
the replacement value types are inferred from the arguments. This direct form
avoids an intermediate builder that would also need to own the lock.

```mojo {doctest="guide_change_entities" global=true}
    created.replace[
        remove=Components[Position](),
    ](Velocity(2.0, 2.0))
    created^.release()
```

> [!Important]
> Selection component-changing calls mutate the same object and return nothing.
> Validation errors preserve its membership and lock, so it can be used again.
> Release it explicitly when finished, or use a `with` block for cleanup.
