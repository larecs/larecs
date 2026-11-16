# Struct constraint audit

Issue [#138](https://github.com/larecs/larecs/issues/138) requests trailing
struct `where` clauses for invariants that apply to every use of a type.
Audited `src/larecs/*.mojo` with Mojo 1.0.0 (`ed45d567`). No ECS behavior,
component ownership, storage layout, or execution policy changes are intended.

| Structs | Invariant moved to the declaration |
| --- | --- |
| `_BitMask`, `_BitMaskIndexIter` | `total_bits >= 8 and total_bits.is_power_of_two()`. Storage is a nonempty power-of-two SIMD byte vector; counts 1, 2, and 4 previously failed in the underlying zero-width SIMD type. The default remains 256 bits. |
| `AtomicValue` | `T == UInt32 or T == Int32`, previously checked only when initializing/operating on the scalar. |
| `AtomicView` | The same scalar restriction, plus `not writable or origin.mut`, previously checked in its raw-pointer constructor. |
| `SyncView` | `not writable or origin.mut`, previously checked in its raw-pointer constructor. |

These constraints reject invalid type-only annotations before constructors or
operations are called. Read-only views can still borrow either mutable or
immutable origins. Synchronized payloads remain general movable values, including
`String`; only atomic scalar storage is limited to 32-bit integers.

## Intentional exclusions

- `ComponentManager` retains its capacity assertion in `_create_registry`.
  Moving `len(ComponentTypes) <= BitMask.total_bits` to the struct declaration
  was probed against the installed compiler. `mojo precompile src/larecs` then
  rejects existing generic wrappers, including `system.mojo`'s
  `ComponentManager[*WorldTs].get_id[T]()`, with
  `invalid bindings for 'ComponentManager': lacking evidence to prove correctness`.
  Propagating proof obligations through all storage, iterator, world, and system
  wrappers is a separate API change. Empty managers and repeated component names
  remain supported; registries intentionally use last-name-wins lookup.
- `Components`, `_TypeChecks`, `_ResourceTypes`, `Resources`, `Captures`, and
  `Filter` are declaration/inspection helpers. Do not impose nonemptiness or
  uniqueness on them: empty packs, repeated filter access declarations, and
  negative uniqueness queries are supported. Resource-add and component-ID
  operations enforce their own uniqueness policies. Filter inclusion/exclusion
  overlap may express an empty result rather than an invalid type.
- `World`, `HostStorage`, `Archetype`, `_ComponentTable`,
  `DeviceComponentStorage`, their row accessors/iterators, `Scheduler`,
  `SystemContext`, `EntitySelection`, and kernel contexts can mention host-only
  component types. A world declares its optional device storage even for `String`
  components. Device/threaded eligibility belongs at execution or transfer, not
  on these general-purpose declarations. Query membership and mutation validity
  likewise depend on the operation, not just its containing struct.
- `DeviceResourceStorage`, `_ResourceInvocation`, `ResourceAccessor`, capture
  storage/accessors/bindings, and resource adapters retain operation-specific
  transfer checks. Declared sources may own allocations while their prepared
  device views have a different representation. Buffer dtype restrictions are
  already enforced by their underlying SIMD/buffer types.
- `_AccessGuard` retains method-specific writable-origin checks: read-only
  `SyncView` declares a `try_write` result type containing a writable guard even
  though calling that operation is forbidden. A blanket guard restriction would
  require changing that API's availability. `CompareExchangeResult` is a plain
  outcome container; it does not itself perform atomic access. `TryAccess` and
  `Synchronized` support general movable payload/guard types.
- `StaticOptional` keeps conditional `Writable` conformance and method-specific
  presence checks. Both present and absent specializations are valid; the element
  need not be writable merely to store it. `Node`/`BitMaskGraph`, `Replacer`, and
  test helper structs already express field requirements through parameter
  traits/types; runtime graph sizes and component removal IDs are operation
  inputs. Remaining nonparametric entity, pool, lock, error, execution, spatial,
  allocation, and resource metadata structs have no parameter invariant to add.

## Compiler evidence

`test/check_struct_constraints.py` compiles paired positive/negative type-only
bindings with `mojo build --emit llvm`, requiring a constraint-declaration diagnostic identifying the rejected struct
(`violated constraint` for value predicates or `invalid bindings` for type
equality predicates). Positive controls
include 8-bit masks, both atomic scalar types, both read-only origin kinds,
nontrivial synchronized payloads, empty/duplicate declaration packs, a full
256-entry registry, composed read/write filters, and host-only world/device
storage type declarations. `test/run_tests.sh` runs this checker for the complete
suite; it can also run independently:

```sh
pixi run -e test python test/check_struct_constraints.py
```

The ordinary bitmask and synchronization suites exercise the same types through
constructors and operations. Full package precompilation checks generic proof
propagation. These are correctness/compiler checks; no controlled performance
measurement is claimed.

Generic functions naming a constrained type must carry the same proof when it
is not implied by their parameter traits. For example, a function accepting
`SyncView[True, T, origin]` with `origin: Origin` needs `where origin.mut`.
The guard-cleanup test carries that proof; the generic bitmask boundary test
forwards its size predicate to both mask and index-iterator declarations.

A direct `SIMD[DType.uint8, 0]()` probe fails with
`SIMD vector length must be a power of two between 1 and 2^15`, confirming that
sub-byte masks were not usable storage. Backend maximum SIMD widths remain
subject to the compiler's existing representation checks.
