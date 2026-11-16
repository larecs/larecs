### Added

- Add typed kernel capture bindings (`Captures`, `ReadCapture`, `MutCapture`,
  `read_capture`, `mut_capture`) that pass host values to CPU and GPU kernels,
  read-only or copied back after the run. ([#174](https://github.com/larecs/larecs/pull/174))

### Changed

- Validate GPU resources by trivial movability instead of requiring
  `TrivialRegisterPassable`; `GPUResourceType` remains as a legacy alias.
  ([#174](https://github.com/larecs/larecs/pull/174))

### Fixed

- Allow CPU kernels written as capturing closures to use required resources.
  ([#174](https://github.com/larecs/larecs/pull/174))

- Include the kernel identity in system profiling zones. ([#174](https://github.com/larecs/larecs/pull/174))
