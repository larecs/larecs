+++
type = "docs"
title = "Synchronization"
weight = 55
+++

Larecs provides atomic scalars and scoped shared-read/exclusive-write access
through `AtomicValue` and `Synchronized`. Their views share protection identity
when copied; owners and acquired guards are noncopyable. This first implementation
provides target-local primitives. Automatic `KernelContext.sync` bindings,
collection domains, and deferred waiting are planned work.

## Atomic updates

Use atomic operations for shared `UInt32` and `Int32` values. `fetch_add` and
`fetch_sub` return the previous value and wrap at the scalar width. Strong
`compare_exchange` returns `exchanged` and `observed`; failure changes no value
through that call. A read view permits loads only.

```mojo {doctest="guide_synchronization" global=true}
from larecs import AtomicValue, Synchronized
from std.atomic import Ordering
from std.testing import assert_equal, assert_false, assert_true

def main() raises:
    """Checks atomic updates and shared/exclusive access.

    Raises:
        Error: If an example result is incorrect.
    """
    var counter = AtomicValue[UInt32](0)
    var updates = counter.write_view()
    assert_equal(updates.fetch_add(1), UInt32(0))
    var result = updates.compare_exchange(1, 5)
    assert_true(result.exchanged)
    assert_equal(result.observed, UInt32(1))
    updates.store[Ordering.RELEASE](7)
    assert_equal(updates.load[Ordering.ACQUIRE](), UInt32(7))

    var state = Synchronized[UInt32](10)
    var access = state.write_view()
    var first_result = access.try_read()
    var second_result = access.try_read()
    assert_true(first_result.is_acquired())
    assert_true(second_result.is_acquired())
    var first = first_result^.take()
    var second = second_result^.take()
    assert_equal(first.value(), UInt32(10))
    assert_false(access.try_write().is_acquired())
    first^.release()
    second^.release()

    var writer_result = access.try_write()
    assert_true(writer_result.is_acquired())
    var writer = writer_result^.take()
    writer.value() += 5
    writer^.release()
    var after_result = access.try_read()
    var after = after_result^.take()
    assert_equal(after.value(), UInt32(15))
```

All public operations default to relaxed atomic ordering. Loads additionally
accept acquire, stores accept release, and updates accept acquire, release, or
`Ordering.ACQUIRE_RELEASE`. Specify ordering as a compile-time argument. Relaxed
counters do not publish neighboring ordinary data. Guard operations always use
acquire/release ordering internally.

## Scoped access and contention

Multiple read guards can coexist; a write guard excludes all other guards for
its domain. `try_read()` and `try_write()` make at most one compare-exchange
attempt and return `TryAccess`. Check `is_acquired()` before consuming the result
with `result^.take()`. False represents `Busy`, including a changed state or
reader-count saturation. Acquiring a guard does not allocate memory.

`guard.value()` lends a reference tied to the guard. The compiler rejects using
it after release or moving its owner while the borrow remains live. Scope exit
releases the guard, including error unwinding. `guard^.release()` explicitly
consumes and releases it; consuming an acquired result without extracting its
guard also releases access. A write error does not roll back partial mutation.

Copies of one view refer to the same payload and state. Read views do not permit
write acquisition. Do not access private fields or create separate state words
for overlapping payloads. Heap-backed payloads additionally require a consistent
protection contract for all mutable reachable storage.

There is no fairness, blocking wait, lock upgrade, or automatic retry. Handle
`Busy` by recording unfinished work or using an application-approved skip. Do
not assume skipping is valid for required updates. The proposed deferred API
is not implemented, and ordinary statements do not suspend on contention.

## Host and device use

The same view methods select CPU-wide or whole-device atomic scope at compilation
(NVIDIA `device`, AMD `agent`).
CPU tests exercise actual parallel workers; this does not add parallel ECS
system execution. Owners can be borrowed directly for host work.

Device support is experimental. Apple currently supports relaxed scalar
load/store/add/subtract only; strong CAS, publication orderings, and guards fail
with explicit diagnostics. CPU/NVIDIA/AMD use the full initial operation set.
GPU compilation probes do not establish actual hardware correctness.

Device payloads, counters, and lock state must
already reside in aligned device-accessible memory. The keyword-only
`AtomicView(unsafe_pointer=...)` and
`SyncView(unsafe_payload=..., unsafe_state=...)` constructors are low-level
adapters: the caller guarantees lifetime, alignment, atomic-only scalar access,
and one initialized canonical lock state for every overlapping payload. They do
not allocate, transfer data, or validate a host pointer's device accessibility.
Guard state must be initialized unlocked before launch and remain live until
all work completes.

Ordinary raw-byte resource/capture checks reject these views and aggregates
containing them: their explicit move/destruction methods prevent treating them
as transferable host pointers. Those paths do not transfer referenced storage
or encode synchronization ownership. Dedicated binding adapters remain unfinished. CPU
and GPU allocations are separate domains; this API does not permit concurrent
CPU/GPU access to one allocation. Backend compilation evidence and hardware
limitations are recorded in decision 0016.
