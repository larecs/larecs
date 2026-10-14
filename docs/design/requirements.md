# ECS requirements

These are the accepted cross-cutting requirements for Larecs, rather than a
release backlog. Acceptance alone does not establish implementation; known
noncompliance is recorded separately under implementation status. Feature-specific
details and reasons live in [decision records](README.md); tests and source code
are the implementation evidence. Update this file when an accepted decision changes a requirement,
and link the relevant decision.

| ID | Requirement | Evidence or detail |
| --- | --- | --- |
| ECS-01 | A `World` declares the component types it can contain at compile time. | [World guide](../src/guide/entities_components_world.md), `src/larecs/world.mojo` |
| ECS-02 | An `Entity` is an identifier for a world-owned row; structural changes may move its components, so external component references must not be retained across them. | [World guide](../src/guide/entities_components_world.md), `src/larecs/entity.mojo` |
| ECS-03 | Entities with the same component composition belong to one logical archetype. Physical stores may be growable cluster-local stores beneath it; entity locations must stay valid when rows move. | [Architecture](architecture.md), `src/larecs/host_storage.mojo` |
| ECS-04 | Queries filter entities and expose read-only row access. A live query keeps its structural lock; copies have independent iteration cursors. | [Query guide](../src/guide/queries_iteration.md), `test/world_entity_iterator_test.mojo` |
| ECS-05 | Systems run through a `SystemContext`; kernels process entities selected by component access filters on the host or, experimentally, a device. Declared resource and capture access governs those calls. | [Systems guide](../src/guide/systems_scheduler.md), [Decision 0002](decisions/0002-gpu-system-execution.md) |
| ECS-06 | Batch creation and component mutations in a system can yield a movable, noncopyable `EntitySelection` containing exactly the affected rows. Its lock lasts until release, destruction, or context-manager exit. | [Decision 0001](decisions/0001-locked-entity-selections.md) |
| ECS-07 | Selection `add`, `remove`, and `replace` update the same selection in place. Selection execution intersects its membership with the kernel filter; empty matches launch no kernel. | [Decision 0001](decisions/0001-locked-entity-selections.md) |
| ECS-08 | Device raw-byte component and resource transfer accepts only types safe for that representation; heap-backed device resources require a separate transfer design. | [Decision 0002](decisions/0002-gpu-system-execution.md), `src/larecs/resource.mojo`, `src/larecs/component.mojo`, [Decision 0018](decisions/0018-portable-resource-adapters.md), [resource tests](../../test/resource_test.mojo) |
| ECS-09 | Each matching kernel row is visited once: host iteration is sequential, while GPU threads partition a prepared row range by global thread index and total launched thread count. | [Decision 0003](decisions/0003-grid-stride-entity-iteration.md), `test/grid_stride_iterator_test.mojo` |
| ECS-10 | User-authored ECS kernel code must be executable unchanged on both host and device; selecting the target must not require a second kernel implementation. | [Decision 0002](decisions/0002-gpu-system-execution.md). Current gaps: host-only lexical closure entry points and types or bindings unsupported by device transfer; test both targets on compatible hardware. |
| ECS-11 | A scoped selection can run a kernel after a component mutation and propagate either an ECS usage error or a general kernel error while releasing its lock. | [Decision 0004](decisions/0004-scoped-selection-errors.md), `test/entity_selection_test.mojo` |
| ECS-12 | Spatial clustering is opt-in: each registered classifier has an explicit read-only component filter, receives an accessor parameterized by that filter, and runs only on matching archetypes. Spatial classification supports multidimensional cells encoded into dimension-independent cluster keys. | [Decision 0005](decisions/0005-filtered-spatial-row-reordering.md). Single owned classifier, read-only filter checks, and bounded multidimensional helpers implemented under [Decision 0010](decisions/0010-spatial-classifier-maintenance.md). Deferred maintenance is implemented under [Decision 0012](decisions/0012-deferred-spatial-maintenance.md). Multiple registrations and overlapping-filter resolution remain future work. |
| ECS-13 | Spatial locality defaults to deferred row reordering within component-defined archetypes; equal-key rows become contiguous there. Opt-in partitions instead group equal-key rows in one growable store per cluster beneath the same logical archetype. All active columns and entity IDs move together; locations and component lifetimes remain valid. | [Decision 0005](decisions/0005-filtered-spatial-row-reordering.md). Accepted design; internal typed permutation, location repair, and lifecycle tests implemented under [Decision 0009](decisions/0009-typed-row-permutation-foundation.md). Classification and maintenance integrated under [Decision 0010](decisions/0010-spatial-classifier-maintenance.md); opt-in growable stores implemented under [Decision 0014](decisions/0014-growable-cluster-stores.md), with synthetic comparisons in the benchmark guide. |
| ECS-14 | Spatial maintenance requires an unlocked world and an explicit user-triggered boundary. It classifies each distinct dirty eligible identity once using final component values; registration, structural mutations, and explicit invalidation rebuild all eligible keys. Mutable input references, declared kernel writes, and device copy-back invalidate without classifying or moving rows. Clean calls do no classification, permutation, transfer, or compaction work. Queries and selections preserve their membership and lock guarantees; identity, eligibility, locations, and component lifetimes remain valid. Physical ordering is a locality optimization, not an exact spatial-query guarantee. | [Decision 0008](decisions/0008-dirty-entity-spatial-classification.md), [Decision 0012](decisions/0012-deferred-spatial-maintenance.md), `test/spatial_test.mojo`, `test/gpu_spatial_test.mojo`. Low-level raw writes require explicit marking or invalidation; references must not survive maintenance. |
| ECS-15 | Spatial placement does not require a special built-in `Cluster` component. Ordinary application components may supply classifier inputs without special write or placement semantics. | [Decision 0005](decisions/0005-filtered-spatial-row-reordering.md) accepts the classifier model. [Decision 0007](decisions/0007-special-cluster-component.md) records the rejected component proposal. Classifier-based clustering implemented under [Decision 0010](decisions/0010-spatial-classifier-maintenance.md). |
| ECS-16 | Partitioned storage preserves component-defined transition nodes, one growable dense store per logical cluster, source swap-removal, allocation reclamation, staging of structural writes, and exact locked selection membership across stores. Cluster selection requires clean maintenance; host/device execution processes matching physical ranges once, preserving transfer and lifetime rules. | [Decision 0014](decisions/0014-growable-cluster-stores.md), `test/partitioned_spatial_test.mojo`, `test/gpu_spatial_test.mojo`. Cluster lookup scans store metadata; sparse maintenance still copies identity-capacity keys and rebuilds cluster directories. |
| ECS-17 | Kernel synchronization exposes the same host/device access operations and contention semantics: nonblocking scoped shared-read/exclusive-write guards, stable fine-grained collection domains, and 32-bit scalar atomics with explicit ordering. Protection identity and references remain valid throughout execution; unsupported backend guarantees fail clearly. | [Decision 0016](decisions/0016-kernel-memory-synchronization.md). Standalone scalar and single-value primitives in `src/larecs/sync.mojo`; CPU concurrency and confinement checks in `test/synchronization_test.mojo` and `test/check_synchronization_contracts.py`. Dedicated kernel bindings, collection domains, and hardware GPU validation are pending; Apple initially supports relaxed scalars plus acquire loads and release stores only. Current mutable resources/captures do not gain synchronization from this requirement. |

## Implementation status

Decision 0018 repairs ordinary resource eligibility: owning, pointer-bearing,
nontrivial, and opaque representations are rejected by recursive validation.
Read-only `DevicePassableResource` sources use explicit target-local views and
adapter-owned allocations instead of copying owners. See
[adapter integration](../../test/resource_adapter_test.mojo) and
[raw representation regressions](../../test/resource_test.mojo).

Execution APIs use `on_device`, `DeviceComponentType`, `DeviceResourceType`,
and `constrain_device_safe_*` under
[decision 0015](decisions/0015-host-device-execution-terminology.md). These beta
renames replace the former GPU-named APIs without changing ECS-05 or ECS-08
through ECS-10 or adding accelerator backends.

Performance and safety apply across these requirements: preserve valid
component lifetimes and entity locations after structural changes, avoid
unnecessary full-world work for small selections, and measure changes to hot
paths with the relevant benchmarks. See [AGENTS.md](../../AGENTS.md) for the
project's build, test, and benchmark commands.

PR performance checks must compare bounded workloads against the exact PR base
on the same runner/compiler, validate complete results, confirm sustained
regressions, and retain reproducible evidence. See [decision 0011](decisions/0011-pr-performance-regression-checks.md)
for baseline selection, failure policy, initial coverage, and limitations.
