### Fixed

- Reject component additions that partially overlap existing components
  before mutating storage, and destroy replaced component values during
  archetype-changing migration, for single and batch operations alike.
  ([#212](https://github.com/larecs/larecs/pull/212))

- Preserve stale-handle invalidation across `EntityPool.reset`. ([#212](https://github.com/larecs/larecs/pull/212))

- Reject duplicate resource types within a single `add` call. ([#212](https://github.com/larecs/larecs/pull/212))

- Track valid device column rows independently from allocation capacity, and
  complete device kernel runs that match no entities successfully. ([#212](https://github.com/larecs/larecs/pull/212))
