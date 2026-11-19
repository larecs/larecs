### Added

- Add experimental opt-in `backend=ExecutionBackend.HOST_THREADED` host execution for ordinary and
  selected kernels, with `World(execution_config=...)` worker budgets and
  dynamically claimed contiguous chunks. Threaded runs admit pointer-free
  components and read-only or concurrently mutable resources and reject
  unsafe bindings and world lifecycle changes. Types with `StaticTuple` or `InlineArray` fields of
  scalars can conform to `PlainValue` to declare a pointer-free
  representation. ([#187](https://github.com/larecs/larecs/pull/187), [#189](https://github.com/larecs/larecs/pull/189), [#191](https://github.com/larecs/larecs/pull/191))
