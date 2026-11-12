+++
type = "docs"
title = "Coordinate shared writes"
weight = 6
+++

Compute one shared result, the total displacement of all particles, without a
data race. Each particle writes its own output in the kernel, and one caller
sums the outputs after `run` returns. This works on every target, including
[threaded chunks](../threaded) and [device threads](../device), where many
invocations run at once. For data you own outside the world, Larecs also
provides standalone atomic values and guarded values.

Start with [Update entities with systems and kernels](../../systems_kernels).
Larecs does not bind synchronization primitives to kernels automatically; see
[compatibility and status](../../../reference/compatibility).

## Write a separate output for each particle

The stage uses the [portable particle model](../#the-portable-particle-model)
and adds a `Displacement` component that belongs to each particle.

{{< example file="particles/shared_outputs.mojo" region="model" >}}

{{< example file="particles/shared_outputs.mojo" region="kernel" >}}

`write[Displacement]()` grants set-only access, so the kernel must `set` the
output on every row it visits. No two rows share an output, so the kernel needs
no synchronization on any target. A resource or a mutable capture slot, by
contrast, is one value that every invocation would write.

## Reduce after the kernel returns

The system sums the outputs once `run` has returned:

{{< example file="particles/shared_outputs.mojo" region="reduction" >}}

`run` is synchronous, so the query sees every written `Displacement`. One caller
sums all 37 outputs to `(9.25, 18.5)`; nothing writes `total` concurrently.

The driver creates the particles and also runs the atomic and guard checks
shown later on this page:

{{< example file="particles/shared_outputs.mojo" region="check" >}}

From the repository root, run:

```sh
pixi run mojo run -I src examples/particles/shared_outputs.mojo
```

The PASS line means the host reduction and the host primitive checks succeeded.

## Variations

### Reduce in several passes

For a parallel reduction, write partial results to disjoint per-particle or
per-group components, then combine them in a later `run` or on the host. Each
pass reads only output that an earlier, finished call wrote.

### Use a single writer

One designated writer may update a shared value when it does not need other
threads' unfinished results, as the [capture
count](../captures#declare-explicit-slots-for-a-thin-kernel) does with global
thread zero. A thread-zero branch is not a barrier.

### Update data you own with atomic or guarded values

These primitives work on storage you own, outside the world:

{{< example file="particles/shared_outputs.mojo" region="primitives" >}}

- {{< api AtomicValue >}} owns a `UInt32` or `Int32` scalar, and
  {{< api AtomicView >}} borrows it. `fetch_add` returns the previous value.
  `compare_exchange` reports whether it exchanged and which value it observed.
  Operations use relaxed ordering unless you pass an ordering, such as
  `store[Ordering.RELEASE]` and `load[Ordering.ACQUIRE]`, at compile time.
- {{< api Synchronized >}} owns guarded data, and {{< api SyncView >}} borrows
  it. `try_read` and `try_write` make one attempt and never wait. Check
  {{< api TryAccess.is_acquired is_acquired >}} before you consume the attempt
  with `take`. Several readers may hold the value at once; a writer excludes
  everyone else. The guard releases at scope exit or through `release`.

A false `is_acquired` means *Busy*: the single attempt met a conflicting guard,
a state that changed during the attempt, or the maximum reader count. Larecs
does not retry. Record the unfinished work for a later pass, or skip the update
only if your application can lose it.

## Failures and limits

| Failure | Cause and fix |
| --- | --- |
| Wrong totals from a shared resource or capture | Several invocations wrote one value. Write per-particle output and reduce after `run`. |
| `try_read` or `try_write` returns Busy | The attempt met a conflicting guard, a concurrently changed state, or the reader limit. Do not spin; defer the work to a later pass. |
| Compile error for an ordering, compare-exchange, or guard on an Apple GPU | Apple devices support only relaxed or acquire loads, relaxed or release stores, and relaxed add and subtract. Use per-particle output instead. |
| Compile error when an `AtomicView` or `SyncView` is in a resource or capture | Views do not transfer to kernels. Use per-particle output, or a [mutable adapter](../../../reference/resources#mutable-adapters) that manages its own atomic buffer. |
| Ordinary data written next to a relaxed counter is not visible | Relaxed operations order nothing else. Use release stores and acquire loads to publish data. |

[Structural locks are not
mutexes](../../../reference/compatibility#structural-locks-are-not-mutexes);
neither are resource leases. The [synchronization
reference](../../../reference/spatial_sync#synchronization-primitives) lists
supported orderings per backend, guard rules, and device memory requirements.

## Complete program

{{< example file="particles/shared_outputs.mojo" full=true >}}

## Next steps

- [Run threaded host kernels](../threaded) and [Execute on a device](../device)
  run the per-particle kernel concurrently.
- [Synchronization internals](../../../inside/architecture/synchronization)
  explains atomic scope and guard state.
