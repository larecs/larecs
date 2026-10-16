# Changelog

## [Unreleased](https://github.com/larecs/larecs/compare/v1.0.0b1...main)

### Added

- Add experimental opt-in `threaded=True` host execution for ordinary and exact
  selected kernel calls, with fixed `World(execution_config=...)` worker-task
  budgets and dynamically claimed contiguous chunks. Keep ordinary sequential
  execution and below-cutoff whole-range fallback unchanged. Admit pointer-free
  accessed components and explicit read-only resources, including shared
  `KernelView` adapters; reject unsafe bindings and active-world lifecycle changes.
  Validate Linux concurrency; macOS arm64 validation remains pending.
  Trivial types with `StaticTuple` or `InlineArray` fields of scalars can
  conform to the `PlainValue` marker to declare a pointer-free representation
  that reflection cannot inspect.

- Add source-declared `DevicePassableResource` adapters, portable read-only
  views, `BufferResource`, and source-keyed allocation reuse. Kernels keep
  `get[Source]()` on host and device; current source edits and replacements
  require no rebinding. Add `Resources().read/write/read_write` declarations.


- Add target-local `AtomicValue` and `Synchronized` owners with shared views,
  32-bit atomic operations, nonblocking read/write guards, and compiler-enforced
  guard borrows. CPU tests cover actual concurrent workers; device paths are
  experimental; Apple initially supports relaxed scalar operations plus acquire
  loads and release stores.
  Dedicated ECS bindings, collection domains, and deferred waiting remain planned.

- Add opt-in growable cluster-local partitions beneath logical component-defined
  archetypes, with staged structural writes, typed transfers, source swap-removal,
  allocation reclamation, and exact locked `SystemContext.select_cluster`
  membership. Ordinary queries, bulk changes, and CPU/GPU execution traverse
  cluster stores while preserving entity locations and component lifetimes. Retain
  deferred row reordering as the default; add paired maintenance/scan/cell-frame
  benchmarks and capacity-derived memory evidence for both layouts.

- Add a shared PR performance gate with twelve CPU ECS cases alongside the
  spatial suite, paired base/current sampling, confirmed regression failures,
  and retained JSON, Markdown, and diagnostic evidence on Linux and macOS.

- Add small spatial layout/cadence comparisons and same-runner performance
  regression checks to the complete PR test suite.

- Add owned read-only spatial classifiers, explicit full-scan row maintenance,
  and checked grid/Morton-key helpers. Maintenance groups equal keys within
  existing archetypes while preserving entity locations and component lifetimes.

- Support `with` blocks for `EntitySelection`, including in-place mutation
  chains and automatic lock release on normal, early, and exceptional exits.

- Add movable, noncopyable `EntitySelection` results for system batch creation
  and filtered component changes, with in-place add/remove/replace chains and
  reusable CPU/GPU kernel execution over exact selected rows.

### Changed

- Stage high-level device transfers in owned buffers and publish downloads only
  after successful completion. Drain failures; reject further execution if
  completion cannot be confirmed. Reject resource changes during active leases.
- Reject owning, pointer-bearing, nontrivial, and opaque ordinary device
  resources. Migrate heap-backed device sources to read-only adapters; opaque
  fixed arrays require an explicit supported representation. Legacy
  `Resources[T]()` remains `read_write` for ordinary resources.


- Remove spatial `block_capacity`: each logical archetype/cluster now owns one
  contiguous growable store. Classifier configuration controls cluster granularity;
  keep staging, typed transfers, exact selections, and empty-store reclamation.

- Launch device kernels with 256-thread blocks instead of 16, so blocks fill
  whole warps/wavefronts and occupancy is no longer limited by the
  per-multiprocessor block count. Cap the grid at the thread-based upper bound
  of one resident wave, where the device reports it; larger row counts are
  covered by the grid-stride loop.

- Rename the beta execution option `on_gpu` to `on_device`,
  `GPUComponentType`/`GPUResourceType` to
  `DeviceComponentType`/`DeviceResourceType`, and the
  `constrain_gpu_safe_components`/`constrain_gpu_safe_resources` helpers to
  `constrain_device_safe_components`/`constrain_device_safe_resources`.
  Use host/device terminology for execution and transfers while retaining
  CPU/GPU for hardware. Existing callers must update these names; execution
  behavior and supported hardware are unchanged.

- Defer spatial classification until explicit maintenance, deduplicating dirty
  entity identities across mutable input references, setters, CPU kernels,
  selected execution, and GPU copy-back. Clean boundaries skip work; structural
  changes request full rebuilds. Add explicit entity marking/full invalidation
  for raw writes and preserve cached keys and pending work after classifier errors.

- Share CPU resource binding and bounded kernel context setup across ordinary
  and selected execution, with lazy matching-range discovery and no temporary
  CPU range metadata.

- Prefer selection kernels over iterating low-level host-storage batch mutation
  results; selections keep structural changes locked until explicit release or
  destruction.

## [1.0.0b1 (2026-09-14)](https://github.com/larecs/larecs/compare/v0.5.0b4...v1.0.0b1)

### Breaking changes

- Update to Mojo 1.0 and adjust the public API to the stable language release.
- Rename `Resources` to `ResourceStorage`; `Resources` now denotes a compile-time list of resource types that a system/kernel declares it needs.
- Rename `Storage` to `HostStorage` and add a mirrored `DeviceStorage` for GPU execution.
- Replace the `Query` builder with filtered iterators: `HostStorage.query` now takes compile-time filters, locks immediately, and enforces read-only access (component mutation goes through systems).
- Replace `MaskFilter` with a new comptime `Filter` type, with `World.filter` and exclusive filters built on top of it.
- `ArchetypeRowAccessor.get[T]()` is now checked against the query filter at compile time; the previous runtime-checked behavior is available as `unsafe_get[T]()`.

### Added

- New `System`/`SystemContext`/`KernelContext` API for writing ECS logic that runs unchanged on CPU or GPU, including `DeviceResourceStorage`, grid-stride GPU iteration, and CPU/GPU execution benchmarks.
- Expose `HostStorage.assert_alive` for typed validation of entity liveness.
- [`mojo-tracy`](https://github.com/moseschmiedel/mojo-tracy) integration for profiling with [Tracy](https://github.com/wolfpld/tracy)

### Fixed

- Move components correctly during archetype migration.
- Preserve component lifecycle invariants and world mutations across system dispatch.
- Fix several interior-origin bugs affecting `ResourceStorage` and `HostStorage.get()`.

## [0.5.0b4](https://github.com/larecs/larecs/compare/v0.5.0b3...v0.5.0b4)

### Hotfix

- Strip leading 'v' from release version tags in CI.

## [0.5.0b3](https://github.com/larecs/larecs/compare/v0.5.0b2...v0.5.0b3)

### Hotfix

- Authentication with Prefix.dev in CI for package upload.

## [0.5.0b2](https://github.com/larecs/larecs/compare/v0.5.0b1...v0.5.0b2)

### Hotfix

- Define matrix in CI for release builds.

## [0.5.0b1](https://github.com/larecs/larecs/compare/v0.4.0...v0.5.0b1)

### Breaking changes

- Enable non-trivial types for components.
- Unify Archetype iterators into a single `_ArchetypeIterator`
- Use `rattler-build` as build system to produce Conda packages.
- Update the utilized Mojo version to 1.0.0b3.dev2026062206 and adjust the code accordingly.
- Revisit which structs are only `Copyable` and which can be also `ImplicitlyCopyable`

    #### Copyable
    - \_ArchetypeByListIterator
    - \_ArchetypeByMaskIterator
    - Archetype
    - BitMaskGraph
    - BitPool
    - \_EntityIterator
    - EntityPool
    - LockMask -> LockManager

    - Resources
    - StaticOptional
    - StaticVariant
    - UnsafeBox
    - World

    #### ImplicitlyCopyable
    - BitMask
    - Component
    - Entity
    - EntityIndex
    - LockedContext
    - Node
    - Query
    - QueryInfo

- Rename `_ArchetypeIterator` to `_ArchetypeByMaskIterator`
- Rename `LockMask` to `LockManager`
- Remove all `hint_trivial_type` and `run_destructors` parameters from containers that leaked them from their underlying
  List attribute
- Remove `BitMask.without` method
- Add `BitMask.set` overloads that work with multiple component IDs at once

### Other changes

- Marked and skipped execution of buggy benchmarks.
- Implement batch component addition as overload of `world.add`
- Implement batch component removal as overload of `world.remove`
- Implement batch component replacing as overload of `world.Replacer.by`
- Remove `unsafe_take` from the `_utils` module
- Add `StaticVariant`
- Add `_ArchetypeByListIterator` to iterate over a given list of archetypes
- Optimize `archetype.reserve` to reduce frequent reallocations
- Add function `_utils.next_pow2` to calculate next power of 2 fast
- Add helper `QueryInfo.matches` to encapsulate query matching logic
- Add bit-wise operations for `BitMask`

## [v0.4.0 (2025-08-06)](https://github.com/larecs/larecs/compare/v0.3.0...v0.4.0)

### Breaking changes

- Update the utilized Mojo version to 25.5 and adjust the code accordingly.

### Other changes

- Use the builtin dict for better performance.
- Change StaticOptional to build on `InlineArray` for simpler code.
- Remove boilerplate code that can now be synthesized automatically.
- Disable some tests that cannot be executed in the new Mojo version due to a bug.

## [v0.3.0 (2025-06-23)](https://github.com/larecs/larecs/compare/v0.2.0...v0.3.0)

### Breaking changes

- Update the utilized Mojo version to 25.4 and adjust the code accordingly.
- Remove the `TypeIdentifiable` trait, the `TypeId` struct, as well as the TypeMaps.
  Instead, resources now use the built-in reflections module to identify types.
- Remove all `get_ptr` functions, since getting a reference is now sufficient if
  using the `ref` keyword. This applies to entities as well as resources.
- Make `Resources` explicitly copyable only.

### Other changes

- Remove the `@value` decorator in favour of the `@fieldwise_init` decorator and explicit trait conformance.
- Refactor the internal type `ComptimeOptional` to `StaticOptional` so as to match the naming conventions of the standard library.

## [v0.2.0 (2025-05-14)](https://github.com/larecs/larecs/compare/v0.1.0...v0.2.0)

### Breaking changes

- Introduce a trait `ResourceType` to define the type of resources and replace the old `IdentifiableCollectionElement` trait.

### Other changes

- Switch to explicit trait conformance.
- Use trait composition instead of inheritance where possible.
- Introduce a new `TypeIdentifiable` trait for types that can be identified by a type ID.
- Move resources into the storage instead of copying them. This is much more performant if resources are large.

## [v0.1.0 (2025-04-08)](https://github.com/larecs/larecs/tree/v0.1.0)

Initial release of Larecs🌲.
