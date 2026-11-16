### Added

- Support `with` blocks for `EntitySelection`, including in-place mutation
  chains and automatic lock release on normal, early, and exceptional exits.
  ([#174](https://github.com/larecs/larecs/pull/174))

- Add movable, noncopyable `EntitySelection` results for system batch creation
  and filtered component changes, with in-place add/remove/replace chains and
  reusable CPU/GPU kernel execution over exact selected rows. ([#174](https://github.com/larecs/larecs/pull/174))

### Changed

- Prefer selection kernels over iterating low-level host-storage batch
  mutation results; selections keep structural changes locked until explicit
  release or destruction. ([#174](https://github.com/larecs/larecs/pull/174))

- Add a general `Error` arm to `LarecsError` that carries kernel and resource
  failures out of entity selection scopes. ([#174](https://github.com/larecs/larecs/pull/174))

### Fixed

- Release the selection lock when a batch mutation fails. ([#174](https://github.com/larecs/larecs/pull/174))
