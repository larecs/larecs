### Breaking changes

- `HostStorage.add_entities` returns rows with compile-time-checked `get[T]()` for the supplied components. If you annotate the iterator type explicitly, set `row_filter` to include those component types, for example `row_filter=Filter().include[Int32]()`, or let Mojo infer the type. ([#325](https://github.com/larecs/larecs/issues/325))
