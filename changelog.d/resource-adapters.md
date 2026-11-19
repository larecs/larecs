### Added

- Add experimental source-declared `DevicePassableResource` adapters with
  portable read-only views, `BufferResource`, source-keyed allocation reuse,
  and `Resources().read/write/read_write` declarations. Kernels use
  `get[Source]()` on host and device, and source edits or replacements need
  no rebinding. `read` binds an adapter's `View[False]`; `write` (fresh
  output) and `read_write` (preserved contents) bind `View[True]` for
  adapters that opt in with `supports_mutation` or, for device and threaded
  runs, `supports_concurrent_mutation`. `ResourceAccess` and the cache
  helpers `upload_mutable`, `fill`, and `download` support writable
  adapters. ([#184](https://github.com/larecs/larecs/pull/184), [#191](https://github.com/larecs/larecs/pull/191))

### Changed

- Stage device transfers in owned buffers and publish downloads only after
  successful completion. Failed runs are drained, and execution stops when
  completion cannot be confirmed. Resource changes during active leases are
  rejected. ([#184](https://github.com/larecs/larecs/pull/184), [#191](https://github.com/larecs/larecs/pull/191))

### Breaking changes

- Reject owning, pointer-bearing, nontrivial, and opaque ordinary device
  resources; pass heap-backed sources through read-only adapters instead.
  Opaque fixed arrays need an explicit supported representation. Legacy
  `Resources[T]()` declarations remain `read_write` for ordinary resources.
  ([#184](https://github.com/larecs/larecs/pull/184))
