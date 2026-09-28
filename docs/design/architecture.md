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
