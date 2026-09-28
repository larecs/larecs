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

- [ ] Share CPU execution plumbing for ordinary and selected ranges, including
  capture and resource binding. Keep full-world range discovery lazy and rerun
  ordinary system/query tests after the refactor.
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

The current released GPU resource path copies raw bytes and does not encode
host heap ownership for the device. Keep existing type restrictions until a
safe transfer model is accepted for release. See
[decision 0002](design/decisions/0002-gpu-system-execution.md). A dictionary-view
prototype is recorded as [proposed decision 0004](design/decisions/0004-gpu-dictionary-resource-views.md)
on `future/gpu-dictionary-resources`; its presence on that branch does not mark
the work released.

- [ ] Decide and document ownership, encoding, lifetime, synchronization, and
  copy-back for heap-backed GPU resources.
- [ ] Implement and test `TileTensor` compatibility under that model.
- [ ] Review and accept or revise the proposed dictionary view design. Before
  release, resolve view alignment and mutable-reference semantics, measure
  packing and upload costs, verify one kernel body on CPU and actual GPU
  hardware, and ensure unsupported dictionary types fail clearly.
- [ ] Update GPU resource guides after API and hardware tests pass. Preserve the
  documented `ResourceStorage.get` `UnsafeAnyOrigin` contract unless Mojo can
  express the ownership relationship.

## Later — lower priority

### Update existing GPU dictionary values from kernels

The proposed [dictionary view design](design/decisions/0004-gpu-dictionary-resource-views.md)
supports lookup only. Keep mutation out of its first public release.

- [ ] Design an existing-key update method, copy changed values back to the
  host dictionary after CPU and GPU runs, and define concurrent GPU write
  behavior. Treat insertion and removal as separate work.

### Close remaining CPU/GPU kernel portability gaps

[ECS-10](design/requirements.md) requires one kernel implementation usable on
both targets. The current CPU-only lexical closure form and GPU transfer limits
leave gaps beyond the heap-backed resource work above.

- [ ] Define how CPU-local closure values or an equivalent explicit binding
  reach GPU kernels without requiring a second kernel body.
- [ ] Compile and execute the same representative kernels on CPU and actual
  GPU hardware; document type restrictions and remaining gaps.

## Unscheduled — no release target

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
