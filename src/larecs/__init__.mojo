"""
Larecs🌲 is a performance-oriented archetype-based ECS for Mojo.

It is based on the ECS [Arche](https://github.com/mlange-42/arche), implemented in the Go programming language.

Larecs🌲 is still under construction, so the API might change in future versions. It can, however, already be used for
testing purposes.

Example:

```mojo {doctest="readme" global=true}
# Import the package
from larecs import World, SystemContext, KernelContext, Filter


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


# A kernel that moves every entity with a Position and a Velocity.
# Component mutation always happens inside a kernel like this one,
# run through a SystemContext -- see it invoked in main() below.
comptime move_filter = Filter().include[Position, Velocity]()


def move(context: KernelContext[move_filter]):
    for entity in context:
        entity.get[Position]().x += entity.get[Velocity]().x
        entity.get[Position]().y += entity.get[Velocity]().y


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

    # We can query entities with specific components, read-only
    for entity in world.storage.query[Filter().include[Position, Velocity]()]():
        _ = entity.get[Position]()
        _ = entity.get[Velocity]()

    # To mutate components, run a kernel through a SystemContext
    var context = SystemContext(world)
    context.run[move]()
```

```mojo {doctest="readme" hide=true}
main()
```

Exports:
 - archetype.ArchetypeRowAccessor
 - archetype.MutArchetypeRowAccessor
 - component.ComponentManager
 - component.ComponentType
 - device_storage.DeviceComponentStorage
 - device_storage.DeviceResourceStorage
 - entity.Entity
 - error.ComponentError
 - error.EntityError
 - error.LarecsError
 - error.UnknownError
 - error.WorldError
 - filter.BitMaskFilter
 - filter.Filter
 - host_storage.HostStorage
 - host_storage.Replacer
 - lock.LockGuard
 - lock.LockManager
 - pool.BitPool
 - resource.Resources
 - resource.ResourceStorage
 - resource.ResourceType
 - scheduler.Scheduler
 - system.System
 - system.SystemContext
 - system.KernelContext
 - types.ComponentId
 - world.World
"""
from .world import World
from .host_storage import HostStorage
from .error import (
    LarecsError,
    WorldError,
    ComponentError,
    EntityError,
    UnknownError,
)
from .component import ComponentType
from .types import ComponentId
from .archetype import MutArchetypeRowAccessor, ArchetypeRowAccessor
from .resource import Resources, ResourceStorage, ResourceType
from .entity import Entity
from .lock import LockGuard, LockManager
from .filter import Filter, BitMaskFilter
from .system import System, SystemContext, KernelContext
from .scheduler import Scheduler
