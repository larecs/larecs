+++
type = "docs"
title = "Spatial clustering"
weight = 85
+++

Spatial clustering groups equal-key entities together in memory **within each
component archetype**. It is an opt-in locality optimization. It does not change
entity IDs or query membership and does not provide exact neighbor queries.

Register one classifier with an explicit read-only filter, then call
`world.maintain_spatial()` when your application wants to refresh row order.
Configuration belongs to the classifier value; the world owns it and copies it
when the world is copied. Registration does not classify or move any rows.

```mojo {doctest="spatial" global=true}
from larecs import World, Filter, SpatialClassifier, grid_cell, morton_key_3d
from larecs.entity import EntityAccessor
from std.testing import assert_equal


@fieldwise_init
struct Position(Copyable, Movable):
    var x: Float64
    var y: Float64


comptime spatial_filter = Filter().read[Position]()


@fieldwise_init
struct Grid(SpatialClassifier):
    comptime Accessor = EntityAccessor[spatial_filter]
    var cell_size: Float64

    def classify(self, entity: Self.Accessor) raises -> UInt64:
        """Computes a planar grid key from declared read-only inputs.

        Args:
            entity: Position accessor valid only during classification.

        Raises:
            Error: If the coordinates or configured cell size are invalid.

        Returns:
            The collision-free Morton key for the current cell.
        """
        ref position = entity.get[Position]()
        return morton_key_3d(
            grid_cell(position.x, self.cell_size),
            grid_cell(position.y, self.cell_size),
        )


def main() raises:
    """Demonstrates explicit maintenance and stable entity identities.

    Raises:
        Error: If world setup, maintenance, or validation fails.
    """
    var world = World[Position]()
    var a = world.storage.add_entity(Position(12, 0))
    var b = world.storage.add_entity(Position(-1, 0))
    world.register_spatial_classifier[spatial_filter](Grid(cell_size=4))
    world.maintain_spatial()

    # Entity IDs still find the same component values after row movement.
    assert_equal(world.storage.get[Position](a).x, 12)
    assert_equal(world.storage.get[Position](b).x, -1)
```

`Filter.read` permits immutable access. Writable `include`/`write` declarations
are rejected at registration, as is an accessor type that does not match the
registration filter. Inclusion, exclusion, and exclusive matching use the same
rules as ordinary queries. Nonmatching archetypes are never classified or moved.
The first implementation accepts one classifier per world; a second registration
raises and leaves the existing policy in place.

The classifier must be deterministic for unchanged component inputs and policy
configuration. It must not mutate the world or retain the accessor or component
references. Equal UInt64 keys identify a cluster, and ascending numeric key order
determines group order. Tie order is not guaranteed. Avoid arbitrary hashes when
you need locality between clusters.

`grid_cell` uses floor, so -0.1 with cell size 1 maps to cell -1. Inputs must be
finite and cell size must be positive. Each resulting cell must lie in
[-1048576, 1048575]. `morton_key_3d` interleaves three biased signed 21-bit cells
without collisions in that range; its default z=0 supports planar grids.
Out-of-range coordinates raise rather than wrapping or merging cells. Use a
custom UInt64 encoding if your application's bounds differ.

Each explicit maintenance pass classifies **distinct dirty eligible entities**
once using their final component values. Repeated writes deduplicate, and a clean
pass returns without scanning rows. Registration and structural mutations (creation,
deletion, add/remove/replace, and batch/selection changes) request a full rebuild.
When every allocated ID is dirty, maintenance uses contiguous full classification.
Only affected eligible archetypes have their cached keys checked and reordered;
unchanged entities can still move to restore contiguous groups.

Mutable `storage.get[T](entity)` access marks classifier inputs even when used
only to read. Prefer read-only queries for observation. Setters mark overlapping
inputs; CPU kernels conservatively mark their matching declared writable ranges,
including exact selected ranges. Read-only declarations and unrelated component
writes do not invalidate classifier inputs. GPU writable copy-back marks the same
host identities; classification remains on the host.

Raw pointers and low-level archetype access bypass tracking. After such writes,
call `world.storage.mark_spatial_dirty(entity)` for each affected live identity,
or `world.invalidate_spatial()` (also available on storage) for a full rebuild.
External changes to otherwise owned policy configuration require full invalidation.
These calls only invalidate; they do not require an unlocked world or move rows.
Do not retain component references across maintenance, including clean passes.

Maintenance prepares all keys and permutations before moving rows,
so a classifier error leaves row order and committed keys unchanged, retains
pending invalidations for retry, and preserves the original
error message. Movement uses typed component lifecycle operations, including for
heap-backed columns the classifier does not read. Fatal allocation or lifecycle
failures do not provide rollback.

Maintenance requires an unlocked world. Release live queries and selections
first, and do not keep component references across the call. In a system, use
`context.world[].maintain_spatial()` after releasing its selections. Writes,
entity changes, kernel completion, and system completion never invoke maintenance
automatically. GPU copy-back updates current host values; the next explicit pass
classifies invalidated identities from those values, and subsequent CPU/GPU kernels see the new row order.

Choose a cadence by measuring your workload. Wide archetypes move more bytes,
and mobile entities may require frequent refreshes. Nearby entities in different
archetypes remain in separate storage. Neighbor search still needs cell
enumeration or an index and distance checks. The dirty-maintenance benchmark compares
updates, tracking, classification, sorting, movement, and location repair against
explicit full rebuilds; it does not establish a spatial workload speedup.
