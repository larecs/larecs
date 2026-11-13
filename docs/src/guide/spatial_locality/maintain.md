+++
type = "docs"
title = "Maintain particle locality"
weight = 1
+++

Keep particles of the same grid cell next to each other in memory, and select
exactly the particles of one cell. Use this when [profiling](../../performance)
shows that a pass reads nearby particles together and suffers from scattered
rows. Grouping changes only where rows live; entity handles and component
values stay the same. It does not find exact neighbors.

Start with [Update entities with systems and kernels](../../systems_kernels)
and [Create and remove entities in batches](../../structural_changes).

## Classify particles by grid cell

The stage uses the [portable particle
model](../../execution/#the-portable-particle-model) and an `Int32` marker for
particles that should not be grouped.

{{< example file="particles/spatial.mojo" region="model" >}}

A *classifier* computes a *cluster key* for each entity: a `UInt64` that names
its group. Entities with equal keys belong to the same cluster. This classifier
uses one cluster per grid cell:

{{< example file="particles/spatial.mojo" region="classifier" >}}

`spatial_filter` decides which entities Larecs classifies: those with a
`Position` and no `Int32` marker. `Grid` implements {{< api SpatialClassifier
>}}; its `Accessor` must use exactly that filter, with read-only access.
{{< api grid_cell >}} rounds a coordinate down to its cell, so `-0.1` with cell
width 1 lies in cell -1. {{< api morton_key_3d >}} combines the cell coordinates
into one key; the planar simulation leaves z at 0. Both raise for coordinates
outside their documented bounds instead of clamping.

## Maintain placement after movement

Movement and maintenance stay separate steps:

{{< example file="particles/spatial.mojo" region="kernel" >}}

{{< example file="particles/spatial.mojo" region="system" >}}

`move` declares `Position` writable, so Larecs marks every classified particle
it visits as *dirty*: its key may be out of date. Positions change immediately,
but rows move only when you call {{< api World.maintain_spatial >}}. Then
Larecs classifies each dirty particle once, using its final position, and moves
rows to match the new keys. Kernels and systems never run maintenance by
themselves.

Maintenance moves rows, so the world must be unlocked. End every query and
selection first, because [empty queries and selections hold
locks](../../../reference/compatibility#empty-queries-and-selections-hold-structural-locks).
Discard component references before maintenance, and look components up again by
entity handle afterwards.

## Choose a placement policy

Registering the classifier chooses how Larecs groups rows; it does not move
rows by itself. The driver runs the same setup under both policies:

{{< example file="particles/spatial.mojo" region="registration" >}}

| Policy | Placement after maintenance |
| --- | --- |
| `partitioned=False` (default) | Larecs sorts the classified rows of each physical store by key, so equal keys become contiguous. The order of equal keys is unspecified. |
| `partitioned=True`, called *partition mode* | Each cluster of each logical archetype gets its own physical store, a *partition*, which starts with room for one row and doubles as it fills. |

![Row ordering groups equal-key identities in one store; partitions move a staged identity into its growable cluster store while keeping the other cluster separate.](/images/spatial-placement.svg)

*The same logical archetype supports two placement policies.*

Letters label entities, and colors and key labels mark clusters. All components
and the entity ID of a row move together. In partition mode, a new particle, or
one whose components changed, waits in a *staging store*: a physical store for
rows that the next maintenance pass will place. Queries and kernels still visit
staged rows.

## Select one cluster

Partition mode can select exactly the particles with one key:

{{< example file="particles/spatial.mojo" region="cluster" >}}

{{< api SystemContext.select_cluster >}} needs partition mode, a clean
maintenance state, and an unlocked world; that is why the first attempt, made
while `staged` waits in the staging store, raises. The selection contains
`walker` and `staged`, which share key `(0, 0)` but belong to different logical
archetypes; only `walker` has a `Velocity` and matches `move`. The membership
stays fixed until you release the selection, even after `walker` moves to
another cell. The selection matches the key exactly, not a radius, and adjacent
keys need not be adjacent cells. For exact neighbors, check the actual distances
in the cells you need, or build a separate spatial index.

The driver checks the grid bounds and both policies:

{{< example file="particles/spatial.mojo" region="check" >}}

From the repository root, run:

```sh
pixi run mojo run -I src examples/particles/spatial.mojo
```

The PASS line means both policies placed and selected the particles as expected
on the host.

## Variations

### Choose a maintenance cadence

A pass with no dirty particles returns without touching rows. Otherwise it
classifies only the dirty particles, but it still copies one key per entity
slot, scans store metadata, and moves every row whose placement changes, with
all of its components. Structural changes make the next pass reclassify every
particle. Maintaining every few steps instead of every step trades placement
accuracy for fewer row moves. [Measure complete
steps](../../performance/measure) to choose, and compare the locality-sensitive
pass on its own as well.

### Report writes that Larecs cannot see

Larecs marks particles dirty when you write positions through `set`, a mutable
`get`, or a kernel that declares the write. Use `read` or read-only queries to
look at positions without marking them. After a write through a raw pointer,
call `world.storage.mark_spatial_dirty(entity)` for each changed particle, or
{{< api World.invalidate_spatial >}} to reclassify everything.

### Move particles on a device

Device movement marks the same particles dirty when it copies `Position` back.
Maintenance and classification still run on the host afterwards.

## Failures and limits

| Failure | Cause and fix |
| --- | --- |
| `maintain_spatial` or `select_cluster` raises a locked-world error | A query, selection, or storage range is still alive, possibly an [empty one](../../../reference/compatibility#empty-queries-and-selections-hold-structural-locks). End it first. |
| `Cluster selection requires clean spatial maintenance` | Particles are dirty or staged. Release old selections, call `maintain_spatial`, then select again. |
| `Cluster selection requires partitioned spatial storage` | Register the classifier with `partitioned=True`. |
| `grid_cell` or `morton_key_3d` raises | A coordinate is not finite, the cell width is not positive, or a cell lies outside the supported range. Change the cell width or the key encoding. |
| `maintain_spatial` raises a classifier error | Larecs keeps the previous rows, keys, and dirty marks. Fix the input and call it again. |
| Particles stay in old clusters after raw writes | Larecs could not see the write. Mark the particles dirty or invalidate, then maintain. |

The [spatial reference](../../../reference/spatial_sync) lists classifier rules,
key bounds, and the exact maintenance contract. The [partition
benchmark](../../../inside/development/reports/partitions#partitioned-storage-comparison)
records measurements for one workload, not a general speed guarantee.

## Complete program

{{< example file="particles/spatial.mojo" full=true >}}

## Next steps

- [Spatial maintenance internals](../../../inside/architecture/spatial)
  explains dirty tracking, classification, and partition placement.
- [Measure complete simulation steps](../../performance/measure) to decide
  whether locality pays off.
