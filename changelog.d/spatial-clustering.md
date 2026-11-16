### Added

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
