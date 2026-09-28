# ECS requirements

These are the accepted cross-cutting requirements for Larecs, rather than a
release backlog. A requirement can expose a current implementation gap; its
evidence column must say so. Feature-specific details and reasons live in
[decision records](README.md); tests and source code are the implementation
evidence. Update this file when an accepted decision changes a requirement,
and link the relevant decision.

| ID | Requirement | Evidence or detail |
| --- | --- | --- |
| ECS-01 | A `World` declares the component types it can contain at compile time. | [World guide](../src/guide/entities_components_world.md), `src/larecs/world.mojo` |
| ECS-02 | An `Entity` is an identifier for a world-owned row; structural changes may move its components, so external component references must not be retained across them. | [World guide](../src/guide/entities_components_world.md), `src/larecs/entity.mojo` |
| ECS-03 | Entities with the same component composition are stored in archetypes; entity locations must stay valid when rows move. | [Architecture](architecture.md), `src/larecs/host_storage.mojo` |
| ECS-04 | Queries filter entities and expose read-only row access. A live query keeps its structural lock; copies have independent iteration cursors. | [Query guide](../src/guide/queries_iteration.md), `test/world_entity_iterator_test.mojo` |
| ECS-05 | Systems run through a `SystemContext`; kernels process entities selected by component access filters on CPU or, experimentally, GPU. Declared resource and capture access governs those calls. | [Systems guide](../src/guide/systems_scheduler.md), [Decision 0002](decisions/0002-gpu-system-execution.md) |
| ECS-06 | Batch creation and component mutations in a system can yield a movable, noncopyable `EntitySelection` containing exactly the affected rows. Its lock lasts until release, destruction, or context-manager exit. | [Decision 0001](decisions/0001-locked-entity-selections.md) |
| ECS-07 | Selection `add`, `remove`, and `replace` update the same selection in place. Selection execution intersects its membership with the kernel filter; empty matches launch no kernel. | [Decision 0001](decisions/0001-locked-entity-selections.md) |
| ECS-08 | GPU raw-byte component and resource transfer accepts only types safe for that representation; heap-backed GPU resources require a separate transfer design. | [Decision 0002](decisions/0002-gpu-system-execution.md), [roadmap](../roadmap.md). A dictionary transfer prototype is [proposed in Decision 0004](decisions/0004-gpu-dictionary-resource-views.md), not accepted as the current release contract. |
| ECS-09 | Each matching kernel row is visited once: CPU iteration is sequential, while GPU threads partition a prepared row range by global thread index and total launched thread count. | [Decision 0003](decisions/0003-grid-stride-entity-iteration.md), `test/grid_stride_iterator_test.mojo` |
| ECS-10 | User-authored ECS kernel code must be executable unchanged on both CPU and GPU; selecting the target must not require a second kernel implementation. | [Decision 0002](decisions/0002-gpu-system-execution.md). Current gaps: CPU-only lexical closure entry points and types or bindings unsupported by GPU transfer; test both targets on compatible hardware. |

Performance and safety apply across these requirements: preserve valid
component lifetimes and entity locations after structural changes, avoid
unnecessary full-world work for small selections, and measure changes to hot
paths with the relevant benchmarks. See [AGENTS.md](../../AGENTS.md) for the
project's build, test, and benchmark commands.
