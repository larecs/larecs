### Added

- Add opt-in device copy reuse with `World.reuse_device_copies(enabled)`:
  device runs skip uploading resources and component columns unchanged since
  their last transfer. `world.resources.read[T]()` and
  `world.storage.read[T](entity)` read without forcing re-uploads, and
  `invalidate_device[T]()` and `invalidate_device_copies()` force them after
  writes through escaped references or raw pointers. ([#192](https://github.com/larecs/larecs/pull/192))
