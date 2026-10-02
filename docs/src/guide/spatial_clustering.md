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
        ref position = entity.get[Position]()
        return morton_key_3d(
            grid_cell(position.x, self.cell_size),
            grid_cell(position.y, self.cell_size),
        )


def main() raises:
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

Each explicit maintenance pass reads **every eligible row**, including already
ordered archetypes. It prepares all keys and permutations before moving rows,
so a classifier error leaves row order unchanged and preserves the original
error message. Movement uses typed component lifecycle operations, including for
heap-backed columns the classifier does not read. Fatal allocation or lifecycle
failures do not provide rollback.

Maintenance requires an unlocked world. Release live queries and selections
first, and do not keep component references across the call. In a system, use
`context.world[].maintain_spatial()` after releasing its selections. Writes,
entity changes, kernel completion, and system completion never invoke maintenance
automatically. GPU copy-back updates current host values; the next explicit pass
classifies those values, and subsequent CPU/GPU kernels see the new row order.

Choose a cadence by measuring your workload. Wide archetypes move more bytes,
and mobile entities may require frequent refreshes. Nearby entities in different
archetypes remain in separate storage. Neighbor search still needs cell
enumeration or an index and distance checks. The maintenance benchmark measures
the cost of scans and movement; it does not establish a spatial workload speedup.
