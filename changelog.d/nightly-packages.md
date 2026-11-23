### Added

- Publish nightly packages built from `main` to
  https://prefix.dev/tree-d/nightly. ([#251](https://github.com/larecs/larecs/pull/251))

### Changed

- Constrain Mojo to the 1.0 release series, with matching MAX and
  `mojo-tracy` ranges for the conda package. ([#174](https://github.com/larecs/larecs/pull/174), [#251](https://github.com/larecs/larecs/pull/251))

### Fixed

- Select a compatible macOS SDK during Pixi activation when the default
  macOS 27 SDK breaks linking. ([#174](https://github.com/larecs/larecs/pull/174))
