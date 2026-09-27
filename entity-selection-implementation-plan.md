# Agent implementation flow: locked entity selections

Implement [the design](entity-selection-design.md) for the first remaining
1.0.0b2 todo, issue #170. This file is the execution checklist; the linked design
is the behavioral contract. Implementation and validation evidence are recorded
below; intentionally retained compatibility work is called out explicitly.

## Working rules

- [x] Read `AGENTS.md` and use `mojo-syntax` for Mojo changes, plus
  `mojo-gpu-fundamentals` for GPU changes. Read `closure-migration` if changing
  closure signatures requires it.
- [x] Inspect the branch and dirty worktree; preserve unrelated user changes.
- [x] Work through phases in dependency order. Check off tasks only after their
  evidence exists; record commands, results, and remaining limitations below.
- [x] Use the commit boundaries below as reviewable implementation units. Do not
  publish, push, or create a release as part of this task.
- [x] Do not re-open settled choices: locked results, context batch entry points,
  consuming selection mutations, reusable kernel execution, intersection-based
  kernel filtering, and mutation results containing only modified entities.
- [x] Resolve routine signature details through compiler experiments. Ask the
  user only if evidence requires changing the agreed semantics.

## 1. Ownership prototype and lock authorization

Suggested commit: `feat: add locked entity selection ownership`

Relevant files: `src/larecs/lock.mojo`, `src/larecs/system.mojo`,
`src/larecs/iteration.mojo`, and a selection module if it avoids circular imports.

- [x] Prototype an origin-bound, movable, noncopyable `EntitySelection` with
  explicit range triples and a single owned guard.
- [x] Compile examples proving repeated borrowed execution, consuming mutation,
  returned selection ownership, release/destruction, and world lifetime safety.
- [x] Choose and document exact public operation names and release syntax;
  mirror existing storage conventions and `SystemContext.run` overloads.
- [x] Add narrow sole-owner authorization to the lock implementation. Validate
  guard manager identity and ownership without temporarily unlocking storage.
- [x] Ensure guard transfer does not allocate a replacement lock.
- [x] Verify one release per guard on normal destruction, move, early return,
  and raised errors; verify that a moved selection cannot be reused or copied.
- [x] Cover empty selections, wrong-owner authorization, and conflicts with
  another active query/guard. Compile-time borrowing restrictions may prevent
  some conflicts publicly; cover the internal runtime check regardless.

Gate: the intended ownership API compiles and its lock lifecycle is tested.
Update the design with compiler-verified signatures before expanding the API.

## 2. Exact-range mutation internals

Suggested commit: `feat: support component mutations on selected row ranges`

Relevant files: `src/larecs/host_storage.mojo`, `src/larecs/archetype.mojo`,
`src/larecs/entity.mojo`, and existing storage/component tests.

- [x] Factor batch mutation internals to accept a bounded range source, preserving
  whole-archetype fast paths and existing validation rules.
- [x] Separate public unlocked-world checks from internally authorized mutation;
  do not add a public boolean that bypasses locks.
- [x] Acquire or transfer the output guard before storage mutation and carry it
  through result construction with no unlock/relock gap.
- [x] Preflight component validation and capacity/metadata work where practical.
  Record the exception guarantee for remaining fallible operations.
- [x] Implement selected add, remove, and replace. Snapshot source ranges so
  newly appended destination rows cannot enter the operation.
- [x] Implement safe partial-row movement and compaction; update locations for
  transferred entities and any unselected source entities moved by swap-removal.
- [x] Reacquire archetype references after operations that may reallocate the
  archetype list. Keep range metadata index-based.
- [x] Restrict in-place replacement to selected rows; verify destruction versus
  initialization for old and newly allocated values.
- [x] Return bounded post-mutation ranges excluding existing destination rows,
  filtered-out source rows, duplicate rows, and zero-length spans.
- [x] Check destination-overlap assumptions and coalesce adjacent result ranges
  where safe. Preserve empty-operation behavior.
- [x] Test disjoint ranges in one archetype, multiple archetypes, existing
  destinations, middle/tail row removal, newly created destinations, in-place
  replacement, empty results, invalid requests, and heap-owning components.
- [x] Verify entity lookup after every mutation and destruction counts for
  removed/replaced/moved values.

Gate: the exact-range engine is correct without relying on kernel execution.

## 3. SystemContext and selection batch APIs

Suggested commit: `feat: expose batch mutations through system contexts`

Relevant files: `src/larecs/system.mojo`, public exports, storage replacement
builders, and the new selection module if introduced.

- [x] Expose batch entity creation on `SystemContext`, returning a locked selection
  that contains only the newly created rows.
- [x] Expose filtered batch add/remove/replace on `SystemContext`, returning the
  modified rows through the same selection type.
- [x] Add consuming add/remove/replace entry points on `EntitySelection`, with
  optional filtering restricted to existing selection membership.
- [x] Preserve replacement builder behavior or provide and document a consistent
  equivalent; ensure intermediate builders preserve lock ownership and origins.
- [x] Return only modified entities after filtered operations. Define an omitted
  operation filter as no additional membership restriction, while preserving
  component-operation validity requirements.
- [x] Ensure unrelated structural operations remain blocked while a result lives.
- [x] Test create/add/replace/remove chains, skipped entities, empty intermediate
  results, lock conflicts before mutation, and explicit release.
- [x] Document public methods with all applicable parameters, arguments, returns,
  constraints, and raised errors as required by `AGENTS.md`.

Gate: batch entry points and chains are usable with one continuously owned guard.

## 4. Shared CPU execution over ranges

Suggested commit: `feat: execute CPU kernels on entity selections`

Relevant files: `src/larecs/system.mojo`, `src/larecs/iteration.mojo`,
`test/system_test.mojo`, `test/capture_test.mojo`.

- [ ] Extract shared execution plumbing that accepts whole-archetype or selected
  range sources without duplicating capture/resource binding logic.
- [x] Keep full-world range discovery lazy where practical.
- [x] Implement selection `.run` for thin kernels and supported CPU closures.
- [x] Intersect the selection with the kernel filter without changing the saved
  selection; offset pointers and use the exact range length.
- [x] Preserve required-resource checks and explicit read/mutable captures,
  including duplicate value types and repeated calls.
- [x] Test untouched unselected rows, partial filter matches, no matches, multiple
  ranges, repeated execution, resources, lexical CPU captures, and explicit
  mutable capture copy-back behavior.
- [x] Verify that kernel row indices are not accidentally advertised as stable
  selection-wide indices across CPU and GPU.
- [x] Run ordinary system/query regression tests after the shared-path refactor.

Gate: selected and ordinary CPU execution share correct execution plumbing.

## 5. Selected GPU packing and copy-back

Suggested commit: `feat: execute GPU kernels on entity selections`

Relevant files: GPU execution in `src/larecs/system.mojo`, device component
storage, `test/capture_test.mojo`, `test/gpu_resource_test.mojo`, and focused new
selection GPU tests.

- [x] Compute packed offsets from matching range counts and upload only selected
  readable spans. Handle write-only columns without unnecessary uploads.
- [x] Launch once over the packed matching length and scatter written spans back
  to the corresponding host ranges.
- [x] Reuse persistent device storage without exposing stale rows from a previous,
  larger selection. Test repeated calls with changing selection sizes.
- [x] Preserve resource and explicit capture transfers, mutable copy-back, and
  existing device/type validation.
- [x] Skip component allocation and launch for empty matches while preserving
  existing binding/resource validation behavior.
- [x] Keep lock and buffer lifetimes valid through synchronization and error
  cleanup. Do not return a usable selection while device writes are outstanding.
- [x] Cover nonzero source offsets, disjoint spans, multiple archetypes,
  preexisting destination rows, filtered chains, read/write/write-only access,
  resources, and mutable captures. Use single-writer or atomic shared updates.
- [x] Mark GPU tests `# SKIP_DEBUG` to avoid the documented Apple Metal crash;
  follow existing GPU ASAN exclusions where required.
- [x] Record actual GPU execution evidence separately from skipped tests.

Gate: real hardware confirms exact selected upload, execution, and copy-back.

## 6. Iterator migration, documentation, and benchmarks

Suggested commit: `docs: migrate batch workflows to locked entity selections`

Split internal iterator retirement into a separate refactor commit if substantial.

- [x] Inventory all uses of `LockedWorldEntityIterator`, `_WorldEntityIterator`,
  mutation `has_start_indices`, and replacement builders.
- [ ] Migrate mutation-result callers to the selection API; share storage internals
  rather than retaining two mutation implementations.
- [ ] Preserve ordinary query behavior, its lock lifetimes, and supported
  copy/move semantics. Replace remaining `_WorldEntityIterator` query duties
  before removing the old type and mutation-only start-index machinery.
- [ ] Update `test/world_entity_iterator_test.mojo`, `test/world_test.mojo`, and
  affected callers; retain equivalent coverage for preserved query behavior.
- [x] Update `docs/src/guide/adding_and_removing_entities.md`,
  `docs/src/guide/changing_entities.md`, and relevant system/query guides.
- [x] Add runnable examples of creation followed by a kernel and filtered
  add/remove/replace chains, including repeated CPU/GPU execution and release.
- [x] Explain filtering, consumption, lock conflicts, empty selections, invalid
  component requests, and migration from the former iterator results.
- [x] Preserve the documented `ResourceStorage.get` `UnsafeAnyOrigin` contract.
- [ ] Add selected-batch benchmarks alongside
  `benchmark/gpu_system_benchmark.mojo` or a focused benchmark file. Measure small
  selections in large worlds, contiguous/disjoint ranges, mutation chains, and
  ordinary full-world execution before/after the refactor.
- [ ] Record workload, hardware, baseline/revised timings, and any regressions.
- [x] Update `v1.0.0b2.md` and `changelog.md` only for completed, verified work.

Gate: documented examples are executable and the performance impact is measured.

## 7. Final validation and handoff

- [x] Run focused tests while implementing each phase; avoid repeatedly running
  the full suite unless failures or later changes justify it.
- [x] Format: `pixi run mojo format src test benchmark`.
- [x] Run all tests: `pixi run tests test`.
- [x] Run extracted guide examples: `pixi run doctest`.
- [x] Generate API docs:
  `pixi run mojo doc -o docs/src/larecs.json src/larecs`.
- [x] Run the affected examples and focused benchmarks using the repository's
  existing tasks; inspect the diff for unintended generated artifacts.
- [x] Confirm no lock leaks, accidental copies, unlocked mutation intervals,
  stale component pointers, or unintended full-world writes remain.
- [x] Confirm real GPU tests ran successfully; report unavailable hardware or
  skipped coverage as a limitation instead of claiming verification.
- [x] Run `git diff --check`, review public API changes and the final diff, and
  reconcile every outstanding checklist item.
- [x] Report delivered behavior, validation evidence, migration requirements,
  performance findings, and any unresolved limitations. Do not mark the overall
  1.0.0b2 release complete: heap-backed GPU resources remain separate work.

## Implementation evidence

The implementing agent should append concise entries here as work proceeds:

| Phase | Commit or files | Checks and outcomes | Limitations or follow-up |
| --- | --- | --- | --- |
| Planning | This file and the linked design | Read `AGENTS.md`, `mojo-syntax`, `mojo-gpu-fundamentals`, and `closure-migration`; inspected the dirty worktree before editing | The two design/plan files were the only initial untracked changes and are now part of the documentation commit |
| Ownership and API | `60e5750`, `40d2776`; `entity-selection-design.md` | Compiler experiments established the origin-bound RAII representation and direct `Components` replacement signature; focused lifecycle, sole-owner, empty, move, release, and raised-error tests pass | Mojo rejects a separately tracked guard pointer alongside the world pointer, so the selection itself owns the lock bit |
| Exact mutation | `60e5750`, `7d5d00c`; `test/entity_selection_test.mojo` | Disjoint and multi-archetype changes, existing destinations, swap-removal locations, empty results, invalid requests, and heap-owning components pass under ASAN | Predictable errors are preflighted; allocation failure after mutation begins is not transactionally rolled back |
| CPU execution | `60e5750`; `37f6e5e` | Thin kernels, closures, resources, explicit mutable bindings, repeated calls, filter mismatch, and untouched rows pass | Selected and ordinary paths reuse capture/kernel/device primitives, but a follow-up can further consolidate their duplicated orchestration loops |
| GPU execution | `60e5750`; `37f6e5e`, `7d5d00c` | Three selected GPU tests executed successfully on Apple Metal: nonzero offsets, changing sizes, write-only columns, resources/captures, and disjoint multi-archetype packing/scatter | `# SKIP_DEBUG` and `# SKIP_ASAN` disable those compile modes; they did not skip runtime execution. Heap-backed GPU resources remain out of scope |
| Migration and docs | Guides, changelog, and `v1.0.0b2.md` | Seven supported guide doctests pass; query and low-level iterator regression tests pass | Low-level `HostStorage` mutation iterators and `has_start_indices` remain for compatibility; public system workflows use selections |
| Benchmarks | `41cbefa`, `e4d07f1`; `docs/src/guide/benchmarks.md` | Apple Metal host: full CPU 100k 0.0253 ms; contiguous CPU 64/100k 0.0000664 ms; disjoint CPU 64/100k 0.000556 ms; add/remove 0.00727 ms; GPU 64/100k 0.379 ms | Current bounded measurements only; no historical pre-change baseline was available |
| Final validation | Working tree at handoff | `pixi run mojo format src test benchmark`; 24/24 test files pass; 7/7 supported doctests pass; API docs generate; focused benchmark runs; `git diff --check` passes | Eight generated API doctests remain on the repository's pre-existing unsupported skip list |
