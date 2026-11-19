### Breaking changes

- Replace `LockedWorldEntityIterator` with bounded `LockedEntityRange`
  storage ranges; `HostStorage.Iterator` specializations use
  `has_ranges=True` instead of `has_start_indices=True`. Inferred low-level
  loops keep working, and batch initialization runs through
  `SystemContext` selections. ([#217](https://github.com/larecs/larecs/pull/217))
