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

The examples in this chapter mutate a `World` directly to demonstrate its
storage API. This is useful for setup and isolated changes. In application
logic, these operations should generally be performed by a
[system](../systems_scheduler) through its `SystemContext`.

```mojo {doctest="guide_add_remove_entities" global=true hide=true}
from larecs import World, Filter, SystemContext, KernelContext

@fieldwise_init
struct Position(Copyable, Movable):
    var x: Float64
    var y: Float64

@fieldwise_init
struct Velocity(Copyable, Movable):
    var dx: Float64
    var dy: Float64

def place_batch(rows: KernelContext[Filter().include[Position]()]):
    """Places each execution-local row one unit farther along the x axis."""
    for row in rows:
        row.get[Position]().x = Float64(row.idx)
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

Systems create batches through {{< api SystemContext.add_entities add_entities >}}.
The result is a movable, noncopyable {{< api EntitySelection >}} containing
exactly the new rows and owning the world's structural-change lock:

```mojo {doctest="guide_add_remove_entities" global=true}
    var context = SystemContext(world)
    var created = context.add_entities(
        Position(0, 0), Velocity(1, 0), count=10
    )
    created.run[place_batch]()
    created^.release()
```

Use a `with` block to release the lock automatically, including when an error
or early return exits the block:

```mojo {doctest="guide_add_remove_entities" global=true}
    with context.add_entities(Position(0, 0), count=10) as selected:
        selected.add(Velocity(1, 0))
        selected.run[place_batch]()
        selected.run[place_batch]()
    # The structural lock is released here.
```

For an existing selection, write `with selection^ as selected:` to transfer
ownership into the manager. The bound selection cannot escape the block's
manager. The manager retains the lock until exit, even if the bound selection
is consumed or explicitly released inside the block.

> [!Note]
> A selection can run kernels repeatedly. Component-changing methods update
> its membership in place and retain the same lock; they return nothing.
> Call `selection^.release()` when finished, or let it be destroyed. While it
> lives, unrelated creation, deletion, and archetype changes are rejected.
> An empty selection is still locked and follows the same rule.

The lower-level `HostStorage.add_entities` remains available for setup code,
and returns `iteration.LockedEntityRange` (also named by the
`HostStorage.Iterator` type alias). It borrows storage and its lock manager,
records exact bounded batch rows, and supports `len`, `Bool`, iteration, and
mutable `unsafe_get` access. Copies share membership metadata but retain
independent cursor positions and structural locks; moves transfer the existing
lock. Exhaustion, including an empty result, retains the lock until destruction.
Use `SystemContext.add_entities` and a selection kernel for system logic; a
storage range has no `.run`, `.add`, `.remove`, or `.release` method.

The beta concrete return type `LockedWorldEntityIterator` was renamed to
`LockedEntityRange`; explicit `HostStorage.Iterator` specializations use
`has_ranges=True` instead of `has_start_indices=True`. Inferred storage loops
need no change. See [decision 0022](../../design/decisions/0022-locked-storage-ranges.md).

## Batch removal

If we want to remove multiple entities at once,
we need to characterize which entities we mean. To that
end, we use queries, which characterize entities
by their components. For example, removing all
entities that have the component `Position`
can be done with {{< api HostStorage.remove_entities remove_entities >}} as follows:

```mojo {doctest="guide_add_remove_entities" global=true}
    # Remove all entities that have a Position component
    world.storage.remove_entities[Filter().include[Position]()]()
```

More on queries can be found in the chapter [Queries and iteration](../queries_iteration).

> [!Tip]
> Adding and removing many components in one go is significantly
> more efficient than adding and removing components
> one by one.
