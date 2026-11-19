### Added

- Add experimental target-local `AtomicValue` and `Synchronized` owners with
  shared views, 32-bit atomic operations, and nonblocking read/write guards
  whose borrows the compiler enforces. On Apple GPUs, only relaxed scalar
  operations, acquire loads, and release stores are supported.
  ([#183](https://github.com/larecs/larecs/pull/183), [#215](https://github.com/larecs/larecs/pull/215))

### Breaking changes

- Reject invalid bitmask storage sizes, atomic scalar types other than
  `UInt32` and `Int32`, and writable atomic or synchronized views over
  immutable origins when the type is declared. ([#215](https://github.com/larecs/larecs/pull/215))
