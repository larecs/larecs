+++
type = "docs"
title = "Maintain particle locality"
weight = 1
+++

Group particles by a bounded grid cell when profiling shows a locality-sensitive
access pattern. Start with [systems and kernels](../../systems_kernels) and
[selections](../../structural_changes). This stage executes on host; device
movement follows [experimental device rules](../../execution/device), and
spatial classification and maintenance still run on host after copy-back.
Locality optimization does not supply an exact neighbor query.

## Declare eligible classifier inputs

Keep position, velocity, and time separate from placement policy.

{{< example file="particles/spatial.mojo" region="model" >}}

The classifier below reads `Position`; movement can write it without changing
the entity's component composition. Stable entity handles survive placement
changes, while component references and row indices do not.

Define a deterministic {{< api SpatialClassifier >}} and a matching read-only
accessor.

{{< example file="particles/spatial.mojo" region="classifier" >}}

`spatial_filter` classifies entities with `Position` and no `Int32` marker.
Only matching archetypes participate. `Accessor` must exactly match the
registration filter, all filter types must belong to the world, and writable
`include`/`write` inputs are rejected. Ordinary include/exclude/exclusive
membership rules still apply. The world owns one copyable classifier value;
a second registration raises. Do not mutate the world or retain accessors or
references from `classify`.

{{< api grid_cell >}} uses floor: `-0.1` at cell width 1 becomes cell -1.
Coordinates and cell width must be finite, width positive, and resulting cells
in `[-1048576, 1048575]`. {{< api morton_key_3d >}} biases each signed 21-bit
axis and interleaves its bits into a collision-free 63-bit key, with z=0 for
this planar simulation. Invalid inputs raise; they never clamp or wrap. Use
an application encoding if these bounds do not fit.

## Run movement before explicit maintenance

The movement filter and kernel stay visible alongside their classifier.

{{< example file="particles/spatial.mojo" region="kernel" >}}

Movement declares `Position` writable, so Larecs marks eligible matching
identities dirty. Read-only declarations or unrelated component writes do not
invalidate classifier inputs. Values change immediately; placement waits.

Call {{< api World.maintain_spatial >}} at the chosen boundary after execution.

{{< example file="particles/spatial.mojo" region="system" >}}

`Move.update` waits for the synchronous kernel, then classifies dirty inputs
using their final host values. Kernel completion and system completion do not
invoke maintenance automatically. End every query/selection first, including
empty or exhausted cursors. Discard component references before maintenance,
even when you expect a clean no-op, and reacquire them by entity handle.

## Compare row ordering with growable partitions

Registration chooses the placement policy; it does not classify or move rows.
The checked driver runs the same setup under each policy.

{{< example file="particles/spatial.mojo" region="registration" >}}

`partitioned=False` is the default: maintenance sorts eligible rows by ascending
numeric key within their component-defined stores. Equal keys become contiguous;
tie order is not guaranteed. `partitioned=True` keeps one growable dense SoA
store per `(logical archetype, cluster key)`. Capacity starts at one row and
doubles as needed. There is no fixed partition row limit or separate chunk-size
setting; key/cell policy controls population. Store traversal is not globally
key-sorted, and separate clusters need not have adjacent allocations.

The figure contrasts the two layouts after explicit maintenance.

![Row ordering groups equal-key identities in one store; partitions move a staged identity into its growable cluster store while keeping the other cluster separate.](/images/spatial-placement.svg)

*The same logical archetype supports two placement policies.*

Letter labels are identities and colors plus key labels identify clusters.
All component columns and entity IDs move together. Row ordering can move
unchanged entities to restore contiguous groups. Partition mode moves a changed
identity into its destination cluster and repairs a source swap-removal;
growing the destination can relocate its existing rows too. Creation and
component transitions stage rows until maintenance; ordinary queries and
host/device kernels still visit matching staged rows. Same-composition
replacement stays in its current physical store until refreshed. Maintenance
releases empty cluster/staging row allocations; nonempty stores retain capacity.

## Select exact maintained cluster membership

The driver captures key `(0, 0)` after maintenance, intersecting it with a
component filter across logical archetypes.

{{< example file="particles/spatial.mojo" region="cluster" >}}

{{< api SystemContext.select_cluster >}} requires partition mode, clean
maintenance, and an unlocked world. Its selection initially contains `walker`
and `staged`, even though only `walker` has `Velocity` and matches `move`.
Movement changes `walker`'s cell, but the selection's membership stays fixed
until release; refresh placement before acquiring the next cluster selection.
Even an empty result owns a structural lock. This is exact equality to the
maintained key, not a radius query. Morton key adjacency does not guarantee
spatial adjacency. Enumerate relevant cells and check actual distances, or
build a separate spatial index, for exact neighbors.

## Track dirty inputs and choose a cadence

A maintenance pass classifies each distinct dirty eligible identity once.
Repeated writes deduplicate; a clean pass scans no rows. Registration,
structural changes, and full invalidation request a full rebuild. If every
allocated identity is dirty, maintenance uses contiguous full classification.

Mutable `storage.get[Position]` marks inputs even if you only read; use `read`
or read-only queries for observation. Setters, declared writable host/threaded
ranges, and device copy-back mark affected inputs conservatively. Raw pointers
or low-level storage writes bypass tracking: call
`world.storage.mark_spatial_dirty(entity)` for each affected live identity or
{{< api World.invalidate_spatial >}} for a full rebuild. External policy changes
also need full invalidation. These calls invalidate without moving rows.

Classifier errors preserve committed keys and row order and retain dirty state
for retry. All fallible classification and reorder planning precedes movement;
fatal allocation/lifecycle failures offer no rollback. Fix the input or policy
and retry at an unlocked boundary.

Measure maintenance together with your workload. Wide component rows increase
bytes moved; sparse partitions add allocations and metadata; ordinary scans
pay binding/traversal per physical store. Active maintenance still copies
identity-capacity keys and rebuilds a temporary cluster directory, and cluster
selection scans store metadata. Structural-heavy steps request full rebuilds.
A locality-sensitive pass can benefit without improving a full step; compare
both [complete-step costs](../../performance/measure).

## Execute and troubleshoot

The final driver checks negative flooring and bounds, both placement policies,
staging, fixed selection membership, and positions retrieved by stable handle.

{{< example file="particles/spatial.mojo" region="check" >}}

Run `pixi run mojo run -I src examples/particles/spatial.mojo` from the repository
root. Its PASS covers host spatial execution, not device spatial validation.

| Failure | Recovery |
| --- | --- |
| Dirty cluster selection | Release old selections, finish explicit maintenance, then select again. |
| Locked-world maintenance/selection | End live queries, selections, and storage ranges, even if exhausted or empty. |
| Invalid grid/Morton coordinate | Check finite inputs, positive width and bounds; change the application encoding if needed. |
| Unexpected placement after raw writes | Mark affected live identities or fully invalidate, then maintain. Do not reuse escaped references after maintenance. |

The [spatial reference](../../../reference/spatial_sync) links exact declarations;
the [partition benchmark](../../../inside/development/reports/partitions#partitioned-storage-comparison)
records scoped measurements rather than a general speed guarantee.

{{< example file="particles/spatial.mojo" full=true >}}
