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

- [x] Share host execution plumbing for ordinary and selected ranges, including
  capture and resource binding. Keep full-world range discovery lazy and rerun
  ordinary system/query tests after the refactor. Shared resource binding and
  bounded context setup are covered by `test/cpu_execution_test.mojo`; host
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

`benchmark/entity_selection_benchmark.mojo` already covers full-world host
execution, small contiguous and disjoint selections in a 100k-entity world,
selected mutation chains, and a selected device case.

- [ ] Run matching workloads before and after the internal refactor, including
  ordinary full-world execution and large whole-archetype batch benchmarks.
  Use isolated checkouts, the same Mojo environment and hardware, and
  sequential runs without concurrent compilation. Commit `bde4e08` is the
  pre-refactor reference; `691cbc4` is available for a pre-selection reference.
- [ ] Record workload sizes, commit IDs, Mojo version, hardware, run method,
  baseline and revised timings, and regressions. Separate actual GPU execution
  from tests or benchmarks skipped because hardware is unavailable.
- [ ] Investigate material regressions before closing the selection migration.

### Scientific resource integration

- [ ] Validate Tree-D's actual sample representation, indexing, and empty-grid
  semantics against [decision 0018](design/decisions/0018-portable-resource-adapters.md).
  The read-only contiguous-buffer API is implemented; application compatibility
  and shading performance need application source and measurements.
- [ ] Migrate Tree-D's leaf-distribution writer from `MutCapture` to a mutable
  adapted resource under [decision 0022](design/decisions/0022-mutable-adapted-resources.md),
  and compare its host and device results and timings.
- [ ] Run `test/mutable_resource_adapter_test.mojo` and the scatter example on
  supported GPUs (Linux and Apple). Device paths are compile-checked only for
  sm_80 and gfx942; Apple targets need the macOS Metal toolchain.

### Skip unchanged device uploads

[Decision 0021](design/decisions/0021-skip-unchanged-device-uploads.md) is
accepted. Implement resources first, then component columns.

- [x] Add resource revisions, the `reuse_device_copies` switch,
  `resources.read`, and explicit invalidation; skip unchanged resource
  preparation.
- [x] Add the transfer counter and the resource stale-copy, escape-hatch,
  failure, world-copy, and disabled-transfer tests.
- [ ] Run the device resource and column tests on a supported GPU (Linux and
  macOS).
- [x] Add per-store column revisions and `world.storage.read[T](entity)`;
  record component column segments and skip matching segment uploads.
- [x] Add the component stale-copy, store-identity, and alternating-filter tests.
- [x] Add 13 repeated unchanged runs to the adapter benchmark.
- [ ] Measure the adapter benchmark on a GPU and Tree-D's `light_benchmark`
  before and after.
- [x] Document the re-obtain-or-invalidate rule in the resource and device guides.

## Later — lower priority

### Broader resource adaptation

- [ ] Probe guard handles for `get` (destructor-released borrow counts under
  ASAP destruction, inner-reference lifetimes) as the path to automatic device
  copy reuse under decision 0021.

- [ ] Design complete-initialization semantics for write-only ordinary shared
  device values. Writable adapted resources are implemented under
  [decision 0022](design/decisions/0022-mutable-adapted-resources.md).
- [ ] Provide a portable atomic maximum for mutable views; compare-exchange
  reductions are unavailable on Apple GPUs in Mojo 1.0.

- [ ] Evaluate shared immutable preprocessing/configuration, construction-input
  caching, and explicit adapter overrides only when measured application costs
  justify a separate ownership/API design. These are outside 0018's first increment.
- [ ] Evaluate `TileTensor` compatibility and `Dict` serialization beyond the
  implemented read-only contiguous-buffer model; reject unsupported
  representations clearly and document validated host/device limits.

### Performance regression coverage

[Decision 0011](design/decisions/0011-pr-performance-regression-checks.md)
defines the bounded CPU gate and per-run evidence.

- [ ] Add disjoint selections, more component widths, and additional structural
  mutation patterns after measuring combined compilation and execution cost
  on Linux and macOS; keep the normal PR check near one minute per runner.
- [ ] Measure larger working sets and device execution on dedicated hardware.
- [ ] Evaluate smaller thresholds using repeated shared-runner noise evidence.
- [ ] Add long-term trend storage if cumulative small regressions justify the
  operational cost; per-run artifacts initially retain evidence for 30 days.

### Close remaining host/device kernel portability gaps

[ECS-10](design/requirements.md) requires one kernel implementation usable on
both targets. The current host-only lexical closure form and device transfer limits
leave gaps beyond the heap-backed resource work above.

- [ ] Define how host-local closure values or an equivalent explicit binding
  reach device kernels without requiring a second kernel body.
- [ ] Compile and execute the same representative kernels on CPU and actual
  GPU hardware; document type restrictions and remaining gaps.

## Unscheduled — no release target

### Kernel memory synchronization

[Decision 0016](design/decisions/0016-kernel-memory-synchronization.md)
accepts a common CPU/GPU API backed by Mojo 32-bit atomics, a nonblocking
reader/writer state protocol, and stable collection domains. Standalone scalar
and single-value primitives are implemented; dedicated bindings, collection
domains, and hardware GPU validation remain pending. Existing access APIs gain
no safety guarantee.

- [x] Validate standalone guard/reference confinement, consuming release, and
  noncopyable results with CPU runtime and negative compiler checks.
- [ ] Finalize dedicated kernel resource/capture synchronization declarations,
  alias rejection, ownership, and guard-bound origins through those adapters.
- [ ] Probe UInt32/Int32 load/store, strong CAS, add/subtract, explicit ordering,
  and CPU/whole-device scopes on the locked release. Record actual CPU/NVIDIA/
  AMD/Apple evidence and reject unsupported combinations clearly.
- [ ] Prove and test the one-word reader/writer state protocol, including reader
  release sequences, writer publication, saturation, and one-CAS contention.
- [x] Implement standalone atomic scalar views and single-value read/write guard
  owners with shared view identity and explicit contention results.
- [ ] Integrate invocation-wide binding identity and target-local transfer
  sidecars without permitting raw resource/capture access to protected bytes.
- [ ] Evaluate [proposed deferred access](design/decisions/0017-deferred-kernel-access.md):
  scoped read/write operations, owned argument/output binding, bounded queues,
  retry passes, exhaustion, and partial-error/copy-back behavior on both targets.
- [ ] Add fixed-size array domains and frozen dictionary-value protection;
  coordinate device collections with heap-backed resource transfer work.
- [ ] Validate concurrent correctness on actual workers/hardware and measure
  contention, metadata, setup, transfer, and complete execution costs.
- [x] Allow acquire loads and release stores on Apple GPU, validated by
  cross-block payload publication on an M4.
- [ ] Extend Apple GPU support to ordered add/subtract, strong CAS, and guards
  while preserving their contracts; the locked compiler lacks strong CAS and
  acquire-release read-modify-write ordering.
- [ ] Publish user guides when the API compiles and validation passes; keep
  exchange, wider/floating/bitwise atomics, blocking waits, and collective APIs
  outside the initial scope until their semantics and backend support are designed.

### Spatial component locality

[Decision 0005](design/decisions/0005-filtered-spatial-row-reordering.md)
accepts filtered clustering and periodic row reordering within archetypes.
The design is accepted; the internal typed permutation foundation is implemented
under [decision 0009](design/decisions/0009-typed-row-permutation-foundation.md).
Classifier registration and explicit maintenance are implemented under
[decision 0010](design/decisions/0010-spatial-classifier-maintenance.md). Spatial
performance evidence includes small synthetic cell workloads; complete
application and memory measurements remain pending.
Deferred dirty-entity classification is implemented under
[decision 0008](design/decisions/0008-dirty-entity-spatial-classification.md) and
[decision 0012](design/decisions/0012-deferred-spatial-maintenance.md). Applications
still choose explicit maintenance boundaries; structural mutations use full
rebuilds. Opt-in cluster-local partitions and exact maintained cluster selections
use one growable store per logical cluster under
[decision 0014](design/decisions/0014-growable-cluster-stores.md).
Synthetic paired comparisons cover clean, sparse, and dense updates;
complete application benefits remain unmeasured.

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
  classification of all eligible rows on full rebuilds and dirty identities on
  other boundaries, absence of implicit
  maintenance after writes or kernel/system completion, nontrivial component
  lifetimes, classifier failures, lock rejection,
  and host/device execution and copy-back after maintenance. Add public guides when
  the API is implemented.
- [x] Compare small uniform, dense, sparse, and mobile cell workloads against
  scrambled rows, including maintenance cadences; run bounded same-runner
  base-versus-PR performance checks on every full CI test run.
- [x] Defer and deduplicate classifier-input invalidations across reference access,
  host/selected execution, structural changes, and device copy-back. Preserve locks,
  identities, eligibility, error retries, and component lifetimes; compare against
  explicit full scans in `benchmark/dirty_spatial.mojo`.
- [ ] Evaluate finer structural invalidation and avoid whole-capacity key scratch
  copying on sparse passes if measured application costs justify the complexity.
- [x] Compare partitioned storage with deferred row reordering using uniform,
  dense, singleton sparse, and moving synthetic cell workloads; include all
  maintenance costs, ordinary query/host scan throughput, capacity-derived memory,
  allocation counts, occupancy, and maintenance cadence in the benchmark guide.
- [ ] Repeat the historical macOS bounded-block comparisons with growable stores.
- [ ] Measure complete application spatial workloads, process/peak memory, device
  timing, additional component widths, and structural-heavy maintenance.
  Synthetic cell-frame results do not establish application benefit.
- [ ] Define overlapping-filter behavior before supporting multiple registered
  clustering functions; preserve one physical row order per archetype.
- [x] Adopt opt-in [partitioned storage](design/decisions/0006-partitioned-spatial-archetype-storage.md)
  with growable cluster stores, staging, swap-removal, reclamation, exact selections,
  and ordinary/batch/host/device integration under decision 0014.
- [ ] Evaluate persistent cluster directories, growth/shrink policies,
  and high-water metadata reclamation if measured workload costs justify them.

### Other features

- [ ] Add CI that executes GPU tests on actual accelerator hardware. Deferred
  until a suitable free or sponsored runner is available; retain existing device
  tests for local hardware runs. Require accelerator availability so skipped
  device paths cannot report successful hardware coverage.
- [ ] Add built-in event-system support.
- [ ] Complete macOS arm64 correctness, actual-concurrency, and performance
  validation for experimental threaded host execution under
  [decision 0019](design/decisions/0019-threaded-host-execution.md). The opt-in
  engine, immutable worker configuration, exact range chunking, resource
  contracts, and Linux validation are implemented. Measure representative
  application kernels, selection/partition overhead, and chunk-size sensitivity
  before claiming portable speedups or production support. Keep the manual
  threaded benchmark outside the bounded PR timing suite until compilation and
  sampling costs are measured on both platforms.
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
