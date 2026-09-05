+++
type = "docs"
title = "Entities, components and the world"
weight = 10
+++

Larecs🌲 is an entity component system (ECS) framework for Mojo.
The ECS concept is composed of three principal elements:

- [Entities](#entities) represent game objects or simulation entities, like individuals in a population model.
- [Components](#components) are the data associated to entities, i.e. their properties or state variables.
- [Systems](../systems_scheduler) contain the game or simulation logic that manipulates entities and their components, using so-called queries.

In an ECS, each entity is "composed of" an arbitrary set of components that can be added and removed at run-time.
This modular design enables the development of highly flexible and reusable games or simulations.
By decoupling the logic (systems) from the data (entities and components),
ECS avoids convoluted inheritance hierarchies and eliminates hard-coded behavior.
Instead, entities can be composed of components to exhibit diverse behaviors without sacrificing modularity.

An ECS engine manages this architecture within a central storage structure known as the "[World](#the-world)".
The engine handles common tasks such as maintaining entity lists, spawning or deleting entities,
and scheduling logic operations, simplifying the development process for users.

Larecs🌲 provides a high-performance ECS framework,
empowering developers to create games and simulation models with exceptional flexibility and efficiency.

## Entities

Entities are the central unit around which the data in
an ECS is organized. Entities could represent game objects,
or potentially anything else that "lives" in a game or simulation.
Each entity can possess an arbitrary
set of components, which can also be used to characterize
an entity. That is, in an ECS, cars would not be directly 
identified as "cars" but rather as something that has 
the components `Position`, `Velocity`, `Fuel reserves`, 
`Engine power`, etc. 

The components are not stored in individual 
objects but rather in a central container, called the [`World`](#the-world). 
Hence, an {{< api Entity >}} is merely an identifier that allows
retrieving the corresponding components from the world.
As such, entities are strictly bound to the world they live in,
but also small in memory and easy to store.

> [!NOTE] 
> Though entities can safely be stored and passed around,
> their components (or pointers to them) should never be stored
> externally, as they can move in memory at any time.

How entities are created and used is discussed in the
[next chapters](../adding_and_removing_entities).

## Components

Components are the data associated with entities, characterizing
their state and properties. Components are represented
via structs: each component type is a different struct.
For example, if we want to model a world in which 
entities may have a position and a velocity, we need to 
define a `Position` and a `Velocity` struct.

```mojo {doctest="guide_entities_components_world" global=true}
@fieldwise_init
struct Position(Copyable, Movable):
    var x: Float64
    var y: Float64

@fieldwise_init
struct Velocity(Copyable, Movable):
    var dx: Float64
    var dy: Float64
```

These structs are not only used to store data. Their
types are also used as unique identifiers for the components
of an entity. That is, they have a similar role to 
a key in a dictionary.

How components can be assigned to entities is described 
in the [following chapters](../adding_and_removing_entities).

> [!Warning]
> Currently, only "trivial" structs are supported as 
> components in Larecs🌲. That is, structs that can be
> copied and moved via simple memory operations. This does
> *not* include structs that manage heap-allocated memory
> such as `List` or `Dict`. Typically, it is not advisable to
> use such objects in the ECS context anyway; however, 
> Larecs🌲 might support such "complex" structs in a future version. 

## The world

The central data structure of Larecs🌲 is the
{{< api World >}}. It stores all data and information about
the state of the entities and their surroundings.
The `World` struct provides the main functionality
of the ECS, such as adding and removing entities,
looking up components, and iterating over entities.

Larecs🌲 gains efficiency and usability by exploiting
Mojo's compile-time programming capabilities.
To that end, it needs to know ahead of time 
which components might turn up in the world, and the `World` 
must be statically parameterized with the component types upon 
creation. This also has the advantage that certain errors
can already be prevented at compile time, which makes the
program safer and faster.

To set up a `World`, simply import it from the `larecs` package
and create a `World` instance as follows:

```mojo {doctest="guide_entities_components_world" global=true}
from larecs import World

def main():
    # Create a world with the components Position and Velocity
    var world = World[Position, Velocity]()
```
