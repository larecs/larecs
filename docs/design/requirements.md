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
| ECS-08 | GPU raw-byte component and resource transfer accepts only types safe for that representation; heap-backed GPU resources require a separate transfer design. | [Decision 0002](decisions/0002-gpu-system-execution.md), [roadmap](../roadmap.md) |
| ECS-09 | Each matching kernel row is visited once: CPU iteration is sequential, while GPU threads partition a prepared row range by global thread index and total launched thread count. | [Decision 0003](decisions/0003-grid-stride-entity-iteration.md), `test/grid_stride_iterator_test.mojo` |
| ECS-10 | User-authored ECS kernel code must be executable unchanged on both CPU and GPU; selecting the target must not require a second kernel implementation. | [Decision 0002](decisions/0002-gpu-system-execution.md). Current gaps: CPU-only lexical closure entry points and types or bindings unsupported by GPU transfer; test both targets on compatible hardware. |
| ECS-11 | A scoped selection can run a kernel after a component mutation and propagate either an ECS usage error or a general kernel error while releasing its lock. | [Decision 0004](decisions/0004-scoped-selection-errors.md), `test/entity_selection_test.mojo` |
| ECS-12 | Spatial clustering is opt-in: each registered classifier has an explicit read-only component filter, receives an accessor parameterized by that filter, and runs only on matching archetypes. Spatial classification supports multidimensional cells encoded into dimension-independent cluster keys. | [Decision 0005](decisions/0005-filtered-spatial-row-reordering.md). Single owned classifier, read-only filter checks, and bounded multidimensional helpers implemented under [Decision 0010](decisions/0010-spatial-classifier-maintenance.md). Multiple registrations and overlapping-filter resolution remain future work. |
| ECS-13 | Spatial locality initially uses periodic row reordering within existing component-defined archetypes. At completion, equal-key rows are contiguous within each matching archetype; all active columns and entity IDs share the permutation, and entity locations and component lifetimes remain valid. | [Decision 0005](decisions/0005-filtered-spatial-row-reordering.md). Accepted design; internal typed permutation, location repair, and lifecycle tests implemented under [Decision 0009](decisions/0009-typed-row-permutation-foundation.md). Classification and maintenance integrated under [Decision 0010](decisions/0010-spatial-classifier-maintenance.md); spatial benefit is unmeasured. |
| ECS-14 | Spatial maintenance requires an unlocked world and an explicit user-triggered boundary. Each maintenance pass classifies every entity in matching archetypes before reordering; applications choose when to incur the scan and reordering cost. Component writes and kernel/system completion do not implicitly run classification or reordering; queries and selections retain their existing membership and lock guarantees. Physical ordering is a locality optimization, not an exact spatial-query guarantee. | [Decision 0005](decisions/0005-filtered-spatial-row-reordering.md). Explicit full-scan maintenance and lock/failure tests implemented under [Decision 0010](decisions/0010-spatial-classifier-maintenance.md). Dirty tracking in [decision 0008](decisions/0008-dirty-entity-spatial-classification.md) remains undecided and unplanned. |
| ECS-15 | Spatial placement does not require a special built-in `Cluster` component. Ordinary application components may supply classifier inputs without special write or placement semantics. | [Decision 0005](decisions/0005-filtered-spatial-row-reordering.md) accepts the classifier model. [Decision 0007](decisions/0007-special-cluster-component.md) records the rejected component proposal. Classifier-based clustering implemented under [Decision 0010](decisions/0010-spatial-classifier-maintenance.md). |

Performance and safety apply across these requirements: preserve valid
component lifetimes and entity locations after structural changes, avoid
unnecessary full-world work for small selections, and measure changes to hot
paths with the relevant benchmarks. See [AGENTS.md](../../AGENTS.md) for the
project's build, test, and benchmark commands.

PR performance checks must compare bounded workloads against the exact PR base
on the same runner/compiler, validate complete results, confirm sustained
regressions, and retain reproducible evidence. See [decision 0011](decisions/0011-pr-performance-regression-checks.md)
for baseline selection, failure policy, initial coverage, and limitations.
