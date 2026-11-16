### Added

- Add experimental opt-in `threaded=True` host execution for ordinary and
  selected kernels, with `World(execution_config=...)` worker budgets and
  dynamically claimed contiguous chunks. Threaded runs admit pointer-free
  components and read-only resources and reject unsafe bindings and world
  lifecycle changes. Types with `StaticTuple` or `InlineArray` fields of
  scalars can conform to `PlainValue` to declare a pointer-free
  representation. ([#187](https://github.com/larecs/larecs/pull/187), [#189](https://github.com/larecs/larecs/pull/189))
