"""
Larecs🌲 is a performance-oriented archetype-based ECS for Mojo.

It is based on the ECS [Arche](https://github.com/mlange-42/arche), implemented in the Go programming language.

Larecs🌲 is still under construction, so the API might change in future versions. It can, however, already be used for
testing purposes.

Example:

```mojo {doctest="readme" global=true}
# Import the package
from larecs import World


# Define components
@fieldwise_init
struct Position(Copyable, Movable):
    var x: Float64
    var y: Float64


@fieldwise_init
struct IsStatic(Copyable, Movable):
    pass


@fieldwise_init
struct Velocity(Copyable, Movable):
    var x: Float64
    var y: Float64


# Run the ECS
def main() raises:
    # Create a world, list all components that will / may be used
    world = World[Position, Velocity, IsStatic]()

    for _ in range(100):
        # Add an entity. The returned value is the
        # entity's ID, which can be used to access the entity later
        entity = world.storage.add_entity(Position(0, 0), IsStatic())

        # For example, we may want to change the entity's position
        world.storage.get[Position](entity).x = 2

        # Or we may want to replace the IsStatic component
        # of the entity by a Velocity component
        world.storage.replace[IsStatic]().by(Velocity(2, 2), entity=entity)

    # We can query entities with specific components
    for entity in world.storage.query[Position, Velocity]():
        # get references to components
        ref position = entity.get[Position]()
        ref velocity = entity.get[Velocity]()

        position.x += velocity.x
        position.y += velocity.y
```

```mojo {doctest="readme" hide=true}
main()
```

Exports:
 - world.World
 - error.LarecsError
 - error.WorldError
 - error.ComponentError
 - error.EntityError
 - error.UnknownError
 - storage.Storage
 - component.ComponentType
 - types.ComponentId
 - archetype.MutableEntityAccessor
 - archetype.EntityAccessor
 - entity.Entity
 - query.Query
 - query.QueryInfo
 - resource.Resources
 - resource.ResourceType
 - scheduler.Scheduler
 - scheduler.System
"""
from .world import World
from .error import (
    LarecsError,
    WorldError,
    ComponentError,
    EntityError,
    UnknownError,
)
from .component import ComponentType
from .types import ComponentId
from .archetype import MutableEntityAccessor
from .resource import Resources, ResourceType
from .entity import Entity
from .query import Query
from .scheduler import Scheduler, System
