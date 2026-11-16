# Changelog

## [Unreleased](https://github.com/larecs/larecs/compare/v1.0.0b1...main)

### Breaking changes

- Select the kernel target with the compile-time
  `backend=ExecutionBackend.HOST/DEVICE` parameter on ordinary and selected
  execution instead of the `on_gpu` flag. Host remains the default;
  unavailable device execution raises instead of falling back, and
  value-taking callables require `HOST`. ([#181](https://github.com/larecs/larecs/pull/181), [#216](https://github.com/larecs/larecs/pull/216))

- Rename `GPUComponentType`/`GPUResourceType` to
  `DeviceComponentType`/`DeviceResourceType` and
  `constrain_gpu_safe_components`/`constrain_gpu_safe_resources` to
  `constrain_device_safe_components`/`constrain_device_safe_resources`.
  ([#181](https://github.com/larecs/larecs/pull/181))

- Reject owning, pointer-bearing, nontrivial, and opaque ordinary device
  resources; pass heap-backed sources through read-only adapters instead.
  Opaque fixed arrays need an explicit supported representation. Legacy
  `Resources[T]()` declarations remain `read_write` for ordinary resources.
  ([#184](https://github.com/larecs/larecs/pull/184))

- Replace `LockedWorldEntityIterator` with bounded `LockedEntityRange`
  storage ranges; `HostStorage.Iterator` specializations use `has_ranges=True`
  instead of `has_start_indices=True`. Inferred low-level loops keep working,
  and batch initialization runs through `SystemContext` selections.
  ([#217](https://github.com/larecs/larecs/pull/217))

- Reject invalid bitmask storage sizes, atomic scalar types other than
  `UInt32` and `Int32`, and writable atomic or synchronized views over
  immutable origins when the type is declared. ([#215](https://github.com/larecs/larecs/pull/215))

### Added

- Support `with` blocks for `EntitySelection`, including in-place mutation
  chains and automatic lock release on normal, early, and exceptional exits.
  ([#174](https://github.com/larecs/larecs/pull/174))

- Add movable, noncopyable `EntitySelection` results for system batch creation
  and filtered component changes, with in-place add/remove/replace chains and
  reusable CPU/GPU kernel execution over exact selected rows. ([#174](https://github.com/larecs/larecs/pull/174))

- Add typed kernel capture bindings (`Captures`, `ReadCapture`, `MutCapture`,
  `read_capture`, `mut_capture`) that pass host values to CPU and GPU kernels,
  read-only or copied back after the run. ([#174](https://github.com/larecs/larecs/pull/174))

- Add experimental opt-in spatial clustering. Owned read-only classifiers and
  checked grid/Morton-key helpers assign entities to cluster-local partitions,
  each a contiguous growable store beneath its logical archetype. Explicit
  maintenance reclassifies only dirty entities, tracked across mutable
  references, setters, CPU kernels, selected execution, and GPU copy-back;
  structural changes request a full rebuild, and raw writes can mark entities
  or invalidate everything. `SystemContext.select_cluster` returns exact
  locked cluster membership, and ordinary queries, bulk changes, and
  execution traverse cluster stores while preserving entity locations and
  component lifetimes. ([#175](https://github.com/larecs/larecs/pull/175), [#179](https://github.com/larecs/larecs/pull/179), [#180](https://github.com/larecs/larecs/pull/180))

- Add experimental source-declared `DevicePassableResource` adapters with
  portable views, `BufferResource`, source-keyed allocation reuse, and
  `Resources().read/write/read_write` declarations. Kernels use `get[Source]()`
  on host and device, and source edits or replacements need no rebinding.
  `read` binds an adapter's `View[False]`; `write` (fresh output) and
  `read_write` (preserved contents) bind `View[True]` for adapters that opt in
  with `supports_mutation` or, for device and threaded runs,
  `supports_concurrent_mutation`. `ResourceAccess` and the cache helpers
  `upload_mutable`, `fill`, and `download` support writable adapters.
  ([#184](https://github.com/larecs/larecs/pull/184), [#191](https://github.com/larecs/larecs/pull/191))

- Add experimental opt-in `threaded=True` host execution for ordinary and
  selected kernels, with `World(execution_config=...)` worker budgets and
  dynamically claimed contiguous chunks. Threaded runs admit pointer-free
  components and read-only or concurrently mutable resources and reject unsafe
  bindings and world lifecycle changes. Types with `StaticTuple` or
  `InlineArray` fields of scalars can conform to `PlainValue` to declare a
  pointer-free representation. ([#187](https://github.com/larecs/larecs/pull/187), [#189](https://github.com/larecs/larecs/pull/189), [#191](https://github.com/larecs/larecs/pull/191))

- Add experimental target-local `AtomicValue` and `Synchronized` owners with
  shared views, 32-bit atomic operations, and nonblocking read/write guards
  whose borrows the compiler enforces. On Apple GPUs, only relaxed scalar
  operations, acquire loads, and release stores are supported. ([#183](https://github.com/larecs/larecs/pull/183), [#215](https://github.com/larecs/larecs/pull/215))

- Add opt-in device copy reuse with `World.reuse_device_copies(enabled)`:
  device runs skip uploading resources and component columns unchanged since
  their last transfer. `world.resources.read[T]()` and
  `world.storage.read[T](entity)` read without forcing re-uploads, and
  `invalidate_device[T]()` and `invalidate_device_copies()` force them after
  writes through escaped references or raw pointers. ([#192](https://github.com/larecs/larecs/pull/192))

- Publish nightly packages built from the `nightly` branch to
  https://prefix.dev/tree-d/nightly. ([#251](https://github.com/larecs/larecs/pull/251))

### Changed

- Launch device kernels with 256-thread blocks instead of 16 and cap the grid
  at one resident wave where the device reports it; the grid-stride loop
  covers larger row counts. ([#182](https://github.com/larecs/larecs/pull/182))

- Stage device transfers in owned buffers and publish downloads only after
  successful completion. Failed runs are drained, and execution stops when
  completion cannot be confirmed. Resource changes during active leases are
  rejected. ([#184](https://github.com/larecs/larecs/pull/184), [#191](https://github.com/larecs/larecs/pull/191))

- Share CPU resource binding and kernel context setup between ordinary and
  selected execution, with lazy matching-range discovery. ([#177](https://github.com/larecs/larecs/pull/177))

- Prefer selection kernels over iterating low-level host-storage batch
  mutation results; selections keep structural changes locked until explicit
  release or destruction. ([#174](https://github.com/larecs/larecs/pull/174))

- Validate GPU resources by trivial movability instead of requiring
  `TrivialRegisterPassable`; `GPUResourceType` remains as a legacy alias.
  ([#174](https://github.com/larecs/larecs/pull/174))

- Add a general `Error` arm to `LarecsError` that carries kernel and resource
  failures out of entity selection scopes. ([#174](https://github.com/larecs/larecs/pull/174))

- Constrain Mojo to the 1.0 release series, with matching MAX and
  `mojo-tracy` ranges for the conda package. ([#174](https://github.com/larecs/larecs/pull/174), [#251](https://github.com/larecs/larecs/pull/251))

### Fixed

- Reject component additions that partially overlap existing components
  before mutating storage, and destroy replaced component values during
  archetype-changing migration, for single and batch operations alike.
  ([#212](https://github.com/larecs/larecs/pull/212))

- Preserve stale-handle invalidation across `EntityPool.reset`. ([#212](https://github.com/larecs/larecs/pull/212))

- Reject duplicate resource types within a single `add` call. ([#212](https://github.com/larecs/larecs/pull/212))

- Track valid device column rows independently from allocation capacity, and
  complete device kernel runs that match no entities successfully. ([#212](https://github.com/larecs/larecs/pull/212))

- Allow CPU kernels written as capturing closures to use required resources.
  ([#174](https://github.com/larecs/larecs/pull/174))

- Release the selection lock when a batch mutation fails. ([#174](https://github.com/larecs/larecs/pull/174))

- Include the kernel identity in system profiling zones. ([#174](https://github.com/larecs/larecs/pull/174))

- Select a compatible macOS SDK during Pixi activation when the default
  macOS 27 SDK breaks linking. ([#174](https://github.com/larecs/larecs/pull/174))

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
