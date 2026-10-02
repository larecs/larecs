# ECS architecture

This is a map of the current implementation and its ownership boundaries.
The [requirements](requirements.md) state the contract; [decision records](README.md)
capture choices and reasons. The [user guide](../src/guide/_index.md) explains
the API in application code.

| Layer                                           | Responsibility                                                                                     | Implementation                                                                        |
| ----------------------------------------------- | -------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------- |
| `World`                                         | Owns the ECS state and declares its possible component types.                                      | `src/larecs/world.mojo`                                                               |
| `HostStorage`, archetypes, and entity locations | Store component columns by archetype and maintain entity-to-row lookup through structural changes. | `src/larecs/host_storage.mojo`, `src/larecs/archetype.mojo`, `src/larecs/entity.mojo` |
| Queries and filters                             | Select matching archetypes/rows for read-only iteration and kernel access declarations.            | `src/larecs/iteration.mojo`, `src/larecs/filter.mojo`                                 |
| `SystemContext`, `KernelContext`, scheduler     | Run ordered application logic and filtered CPU/GPU kernels.                                        | `src/larecs/system.mojo`, `src/larecs/scheduler.mojo`                                 |
| Resources and device storage                    | Bind declared resource data and transfer supported component/resource values for GPU execution.    | `src/larecs/resource.mojo`, `src/larecs/device_storage.mojo`                          |

Queries borrow matching rows under a structural lock. A system can also obtain
an exact-row [`EntitySelection`](decisions/0001-locked-entity-selections.md)
after a batch mutation; that selection owns one lock and can perform further
in-place changes or execute kernels on its current rows. The lock protects
structural validity, while component read/write access is declared by the
filter. CPU and GPU execution share this public model. The GPU path
[packs selected spans](decisions/0002-gpu-system-execution.md) into device
columns and copies written spans back. Kernel row iteration follows the
[grid-stride decision](decisions/0003-grid-stride-entity-iteration.md).

## Spatial-locality extension

[Decision 0005](decisions/0005-filtered-spatial-row-reordering.md) adds opt-in
clustering functions registered with explicit read-only component filters.
Filters select eligible archetypes by component mask. Explicit user-triggered
maintenance scans every row in matching archetypes to compute current spatial
keys, then permutes entity IDs and all active component columns together inside
each matching archetype and updates
entity locations. Archetype identity remains component-based. Maintenance
requires an unlocked world, and applications choose its cadence.
Component writes and kernel/system completion do not implicitly run maintenance.
The initial design has no dirty tracking or persistent move-request queue;
[decision 0008](decisions/0008-dirty-entity-spatial-classification.md) records
dirty-entity classification as undecided and unplanned.

The registration model prepares for different classifiers targeting different
archetypes; multiple registrations and overlap resolution remain future work.
[Decision 0010](decisions/0010-spatial-classifier-maintenance.md) implements one
owned classifier per world with explicit full-scan maintenance. Registration and
maintenance live on `World`; `spatial.mojo` builds keys and permutations before
`HostStorage` applies typed movement and location repair.
[Decision 0006](decisions/0006-partitioned-spatial-archetype-storage.md) records
cluster-local partitions as an undecided alternative, and
[decision 0007](decisions/0007-special-cluster-component.md) records the rejected
special built-in placement component proposal. Track implementation in the
[roadmap](../roadmap.md#spatial-component-locality).
