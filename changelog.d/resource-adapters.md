### Added

- Add experimental source-declared `DevicePassableResource` adapters with
  portable read-only views, `BufferResource`, source-keyed allocation reuse,
  and `Resources().read/write/read_write` declarations. Kernels use
  `get[Source]()` on host and device, and source edits or replacements need
  no rebinding. ([#184](https://github.com/larecs/larecs/pull/184))

### Changed

- Stage device transfers in owned buffers and publish downloads only after
  successful completion. Failed runs are drained, and execution stops when
  completion cannot be confirmed. Resource changes during active leases are
  rejected. ([#184](https://github.com/larecs/larecs/pull/184))

### Breaking changes

- Reject owning, pointer-bearing, nontrivial, and opaque ordinary device
  resources; pass heap-backed sources through read-only adapters instead.
  Opaque fixed arrays need an explicit supported representation. Legacy
  `Resources[T]()` declarations remain `read_write` for ordinary resources.
  ([#184](https://github.com/larecs/larecs/pull/184))
