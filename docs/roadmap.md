# Roadmap

This is Larecs' single list of planned work: a reverse changelog organized by
priority rather than by version number. **Next release** is the intended scope
of the next release, **Later** is lower priority and may follow it, and
**Unscheduled** has no release target. These buckets can change as work is
scoped; they are not release promises. The [changelog](../changelog.md) records
completed changes, and the [design record](design/README.md) states accepted
behavior and requirements.

## Next release — high priority

### Finish entity selection internals

Preserve in-place `EntitySelection.add`, `remove`, and `replace`, context-manager
lock ownership, ordinary queries, and low-level `HostStorage` operations.
[Decision 0001](design/decisions/0001-locked-entity-selections.md) is the
behavioral contract.

- [x] Share CPU execution plumbing for ordinary and selected ranges, including
  capture and resource binding. Keep full-world range discovery lazy and rerun
  ordinary system/query tests after the refactor. Shared resource binding and
  bounded context setup are covered by `test/cpu_execution_test.mojo`; CPU
  paths discover ranges without allocating matching-range metadata.
- [ ] Share batch mutation internals while preserving the whole-archetype bulk
  fast path and exact partial-row behavior. Avoid routing large batches through
  per-entity movement.
- [ ] Migrate callers that use mutation-result iterators for selected execution.
  Keep low-level storage operations usable through a documented adapter or
  return type; `HostStorage` cannot itself return a selection borrowing `World`.
- [ ] Replace `_WorldEntityIterator` query duties before removing that type and
  mutation-only `has_start_indices`. Preserve query lock lifetime, iteration,
  and supported copy/move behavior.
- [ ] Update `test/world_entity_iterator_test.mojo`, `test/world_test.mojo`, and
  affected callers. Cover ordinary queries, low-level compatibility, batch
  results, lock release, and selected mutation chains.

### Measure selection and ordinary-path performance

`benchmark/entity_selection_benchmark.mojo` already covers full-world CPU
execution, small contiguous and disjoint selections in a 100k-entity world,
selected mutation chains, and a selected GPU case.

- [ ] Run matching workloads before and after the internal refactor, including
  ordinary full-world execution and large whole-archetype batch benchmarks.
  Use isolated checkouts, the same Mojo environment and hardware, and
  sequential runs without concurrent compilation. Commit `bde4e08` is the
  pre-refactor reference; `691cbc4` is available for a pre-selection reference.
- [ ] Record workload sizes, commit IDs, Mojo version, hardware, run method,
  baseline and revised timings, and regressions. Separate actual GPU execution
  from tests or benchmarks skipped because hardware is unavailable.
- [ ] Investigate material regressions before closing the selection migration.

### Support heap-backed GPU resources

The current GPU resource path copies raw bytes and does not encode host heap
ownership for the device. Keep existing type restrictions until a safe transfer
model is implemented. See [decision 0002](design/decisions/0002-gpu-system-execution.md).

- [ ] Decide and document ownership, encoding, lifetime, synchronization, and
  copy-back for heap-backed GPU resources.
- [ ] Implement and test `TileTensor` compatibility under that model.
- [ ] Resolve `Dict` compatibility and any `DevicePassable` conversion needed;
  ensure unsupported types fail clearly.
- [ ] Update GPU resource guides after API and hardware tests pass. Preserve the
  documented `ResourceStorage.get` `UnsafeAnyOrigin` contract unless Mojo can
  express the ownership relationship.

## Later — lower priority

### Close remaining CPU/GPU kernel portability gaps

[ECS-10](design/requirements.md) requires one kernel implementation usable on
both targets. The current CPU-only lexical closure form and GPU transfer limits
leave gaps beyond the heap-backed resource work above.

- [ ] Define how CPU-local closure values or an equivalent explicit binding
  reach GPU kernels without requiring a second kernel body.
- [ ] Compile and execute the same representative kernels on CPU and actual
  GPU hardware; document type restrictions and remaining gaps.

## Unscheduled — no release target

### Spatial component locality

[Decision 0005](design/decisions/0005-filtered-spatial-row-reordering.md)
accepts filtered clustering and periodic row reordering within archetypes.
The design is accepted; the internal typed permutation foundation is implemented
under [decision 0009](design/decisions/0009-typed-row-permutation-foundation.md).
Classifier registration and explicit maintenance are implemented under
[decision 0010](design/decisions/0010-spatial-classifier-maintenance.md). Spatial
performance evidence includes small synthetic cell workloads; complete
application and memory measurements remain pending.
The initial strategy scans all eligible entities only when the application
explicitly requests maintenance. [Dirty-entity classification](design/decisions/0008-dirty-entity-spatial-classification.md)
is recorded as undecided and unplanned; it is not an implementation task.

- [x] Define and implement classifier registration with explicit read-only
  filters, key/ordering types, configuration binding, and grid/encoding helpers.
  Specify coordinate bounds and collision handling.
- [x] Implement the internal typed row-permutation primitive, structural-lock
  rejection, location repair, and pre-movement validation. Cover cycles, fixed
  rows, empty archetypes, heap-owned values, and nontrivial lifetimes in
  `test/host_storage_lifecycle_test.mojo`; add a permutation-only benchmark.
- [x] Implement explicit maintenance that skips nonmatching archetypes,
  scans and classifies every eligible row, and permutes all columns and entity
  IDs while preserving locations, component lifetimes, and structural locks.
  Specify allocation/movement error guarantees.
- [x] Cover filter eligibility, negative coordinates, equal-key grouping,
  already ordered and empty archetypes, unchanged query membership, valid locations,
  classification of all eligible rows on each explicit pass, absence of implicit
  maintenance after writes or kernel/system completion, nontrivial component
  lifetimes, classifier failures, lock rejection,
  and CPU/GPU execution and copy-back after maintenance. Add public guides when
  the API is implemented.
- [x] Compare small uniform, dense, sparse, and mobile cell workloads against
  scrambled rows, including maintenance cadences; run bounded same-runner
  base-versus-PR performance checks on every full CI test run.
- [ ] Benchmark complete application spatial workloads against the current layout,
  including classification and bytes moved, ordinary scan overhead, memory
  overhead, maintenance cadence, and uniform, sparse, dense, and mobile cases.
- [ ] Define overlapping-filter behavior before supporting multiple registered
  clustering functions; preserve one physical row order per archetype.
- [ ] Evaluate [partitioned storage](design/decisions/0006-partitioned-spatial-archetype-storage.md)
  against measured reordering costs. It remains proposed and undecided; adopting
  it requires a separate acceptance decision.

### Other features

- [ ] Add CI that executes GPU tests on actual accelerator hardware. Deferred
  until a suitable free or sponsored runner is available; retain existing GPU
  tests for local hardware runs. Require accelerator availability so skipped
  GPU paths cannot report successful hardware coverage.
- [ ] Add built-in event-system support.
- [ ] Add parallel execution where ownership and mutation rules permit it.
- [ ] Improve system control APIs, including a way for systems to stop execution.
- [ ] Revisit value unpacking in queries when Mojo supports the needed form.
- [ ] Add a tabular overview of typical ECS operation costs to the
  [benchmark guide](src/guide/benchmarks.md), using
  [Arche's benchmarks](https://mlange-42.github.io/arche/background/benchmarks/)
  as a reference.

## How to maintain this roadmap

- Add a feature once, under the priority that reflects current intent. Keep
  entries outcome-oriented and link accepted design decisions for behavioral
  details. A proposed idea belongs here without being presented as an accepted
  requirement.
- Move an item between buckets when priorities change; do not create a new
  document for each release. Split a feature into checkable steps only when
  that helps track its completion.
- Check off work only with implementation and validation evidence. Before a
  release, confirm its **Next release** items and record actual GPU runs
  separately from skipped coverage. GPU kernel tests retain `# SKIP_DEBUG` for
  the documented Apple Metal compiler issue.
- Validate changed work with focused tests, then run `pixi run tests test`,
  guide doctests, API-doc generation, formatting, affected examples, and
  focused benchmarks. Review `git diff --check` and generated artifacts.
- At release time, summarize shipped behavior in the [changelog](../changelog.md)
  and remove completed items from this active roadmap. Keep unfinished work in
  the appropriate priority bucket; do not carry a version-specific checklist
  forward.
