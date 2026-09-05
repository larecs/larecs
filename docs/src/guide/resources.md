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
identified at runtime based on their struct name. 

```mojo {doctest="guide_resources" global=true}
from larecs import World, Entity

@fieldwise_init
struct Time(Copyable, Movable):
    var time: Float64
```

## Adding and accessing resources

Resources can be accessed and added via the `resources` field
of {{< api World >}}. Adding a resource is done via the 
{{< api Resources.add resources.add >}} method:

```mojo {doctest="guide_resources" global=true hide=true}

@fieldwise_init
struct Position(Copyable, Movable):
    var x: Float64
    var y: Float64

@fieldwise_init
struct Velocity(Copyable, Movable):
    var dx: Float64
    var dy: Float64

# Two more resource types, used further down this chapter --
# defined here (rather than where they are first discussed) because
# every executable statement in this file has to live in a single
# `main` function, and struct definitions have to come before it.
@fieldwise_init
struct Temperature(Copyable, Movable):
    var temperature: Float64

@fieldwise_init
struct SelectedEntities(Copyable, Movable):
    var entities: List[Entity]
```

```mojo {doctest="guide_resources" global=true hide=true}
def main() raises:
    var world = World[Position, Velocity]()
```

```mojo {doctest="guide_resources" global=true}
    # Add the `Time` resource
    world.resources.add(Time(0.0))
```
The `resources` attribute also allows us to access and
change resources via {{< api Resources.get get >}}
and {{< api Resources.set set >}} methods resembling their
[component-related counterparts](../changing_entities) of `World.storage`.

```mojo {doctest="guide_resources" global=true}
    # Change a resource value via a reference
    world.resources.get[Time]().time = 1.0

    # Get a reference to a resource
    ref time = world.resources.get[Time]()

    # Change the resource value via the pointer
    time.time = 2.0
```

The {{< api Resources.add add >}} and the {{< api Resources.set set >}}
methods also allow to add or set multiple resources at once.
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

## Removing resources

One or multiple resources can be removed via the 
{{< api Resources.remove remove >}} method. The existence
of a resource is checked via the {{< api Resources.has has >}} method.

```mojo {doctest="guide_resources" global=true}
    # Remove the `Time` and the `Temperature` resource
    world.resources.remove[Time, Temperature]()

    # Check if the `Time` resource exists
    if world.resources.has[Time]():
        print("Time resource exists")
    else:
        print("Time resource does not exist")
```
