+++
type = "docs"
title = "Archetypes, columns, and locations"
weight = 2
+++

A **logical archetype** groups entities with identical component composition.
A **physical store** holds one contiguous row collection for that composition.
We keep component masks in a lazy transition graph; its nodes name canonical
dense stores. Partitioned locality can add several physical stores beneath
the same logical node. An internal `Archetype` value represents a physical
store, so its name alone does not imply one store per component combination.

## Columns contain component values

The memory diagram shows one store with `Position` and `Velocity` active.

![A store owns entity IDs and separate Position and Velocity columns. Each Position row contains both x and y, and each Velocity row contains dx and dy. Inactive component slots hold no allocation.](/images/component-memory.svg)

*Columns separate component types; fields remain together inside each value.*

The typed component table tracks a mask, live length, shared capacity,
per-column revisions, and store incarnation (a fresh number for each new store).
Its fixed component-ID-indexed
array contains column descriptors. Each active descriptor owns an optional
allocation and type-specific lifecycle functions; inactive descriptors have
no component allocation. Entity IDs have a separate allocation. Columns
and IDs share row indices, but their allocations are independent.

`Position.x` and `Position.y` are fields in each `Position` struct. They are
not two scalar columns. The same applies to `Velocity.dx/dy`. Spare capacity
is uninitialized storage, not live component objects. The diagram's boxes
describe ownership and indexing, not header offsets, pointer packing, a
stable ABI, or a CPU SIMD-batch API. In particular, the thesis's pointer-slot
sketch must not be read as today's descriptor layout.

## Typed lifecycles

Host components satisfy {{< api component.ComponentType ComponentType >}}
(`Copyable & Deinitable`); they can own heap data. `_ComponentColumn` erases
the concrete type while retaining typed operations for copying, moving,
destroying, swapping, and allocating values.

| Operation | Treatment of live values |
| --- | --- |
| Copy a store | Copy-construct each initialized value into independent column storage. |
| Grow capacity | Allocate typed storage, move live values into it, then release the old allocation. |
| Remove a row | Destroy removed values and move the last row into the hole when necessary. |
| Permute rows | Swap entity IDs and every active component column together, preserving owners. |
| Destroy a store | Destroy its live values once, then release column allocations. |

Raw byte transfer is a separate device eligibility boundary; support for an
owning host component does not make that component device-safe or eligible
for threaded host work. See the [execution contracts](../../../reference/execution).

## Structural transitions and identity

Adding a component changes logical composition. The destination is the
canonical store for the new mask, including when the source is a cluster
store. In partition mode that destination stages rows until maintenance.
The diagram follows particle B while particle C fills its old row.

![Adding Velocity to B moves its Position from source row 1 into the Position-Velocity store, initializes Velocity, moves C from the source tail into row 1, and repairs both entity locations.](/images/structural-transition.svg)

*B keeps its identity while its location changes; C's location changes too.*

Before touching initialized storage, `_ComponentMigration` separates retained,
removed, replaced, and added types, and checks missing removals or overlapping
additions. Retained values move without destruction at the old location.
Removed and replaced values stay initialized until destruction; new values
initialize the destination. Swap-removal then repairs the source hole without
destroying already moved values a second time. Typed row-permutation validation
also completes before its first swap. These checks are not a promise of
transactional rollback for arbitrary allocation failure.

{{< api Entity >}} is an ID/generation pair. The entity pool tracks liveness
and recycling; `_entity_locations[id]` maps a live identity to physical-store
index and row. All row movement repairs that mapping, including the tail row
used by swap-removal. A copied handle survives relocation, whereas an external
component reference cannot survive a structural change or spatial maintenance.
An ID from one world is not a cross-world reference.

Implementation: {{< source "archetype.mojo" >}},
{{< source "host_storage.mojo" >}}, {{< source "graph.mojo" >}},
{{< source "entity.mojo" >}}, {{< source "pool.mojo" >}}.
Evidence: {{< repo "test/host_storage_lifecycle_test.mojo" >}},
{{< repo "test/partitioned_spatial_test.mojo" >}};
{{< repo "docs/design/decisions/0009-typed-row-permutation-foundation.md" "decision 0009" >}}
records movement guarantees.
