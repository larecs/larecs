---
id: "0016"
title: "Kernel memory synchronization"
status: accepted
status_notes: |
  Accepted design; standalone scalar and single-value primitives are partially
  implemented in src/larecs/sync.mojo. Dedicated kernel bindings, collection
  domains, and hardware GPU validation remain pending. The initial Apple GPU
  API is limited to relaxed scalar operations. Names below describe the full
  intended API; compile-tested usage is in the synchronization guide.
---

# Decision 0016: Kernel memory synchronization

## Context

Entity iteration assigns each matching row to one worker, but resources and
explicit captures are shared by those workers. An immutable access may coexist
with other immutable accesses; a mutable access must exclude every other access
to the same protected memory. A scalar counter often needs an atomic operation
rather than a guard. Arrays and dictionaries need protection boundaries smaller
than the entire collection.

The current host executor is sequential. The device executor is concurrent, and
the same user kernel must remain usable with future CPU worker threads. Existing
`LockManager` and `LockGuard` prevent structural ECS changes; they are explicitly
not thread-synchronization primitives. Declaring `MutCapture[T]` or retrieving a
mutable resource does not make concurrent writes safe.

## Decision

Adopt three complementary access mechanisms: immutable or disjoint access
without locks, guarded shared data, and atomic scalars. Synchronization is opt-in
and belongs to a protected storage identity, not to a variable name or a temporary
reference. Existing raw access APIs retain their current contract; the new safe
binding path must not expose an alternative unguarded route to protected bytes.

### Common host and device API

Use the same kernel methods, return semantics, ownership rules, and contention
handling on CPU and GPU. Select the target only at `run(..., on_device=...)`.
Compile-time adapters around `std.atomic.Atomic` and `std.atomic.Ordering`
implement both targets. The algorithm and behavior are accepted here; exact
Mojo signatures must still pass origin-confinement validation.

| Public concept | Kernel operations | Underlying primitive |
| --- | --- | --- |
| `Synchronized[T]` | `try_read`, `try_write` | One 32-bit atomic reader/writer state |
| `ReadGuard[T]` | Immutable `value` access; scope release | Acquire CAS, release reader decrement |
| `WriteGuard[T]` | Mutable `value` access; scope release | Acquire CAS, release writer store |
| `SynchronizedArray[T]` | `element(index)` returns a protected view | The same state protocol per element or fixed chunk/stripe |
| Frozen dictionary values | Lookup returns a protected value view | The same state protocol with stable value slots |
| `AtomicValue[T]` | `load`, `store`, `compare_exchange`, `fetch_add`, `fetch_sub` | Mojo scalar atomics |

Choose no separate CPU mutex or GPU semaphore for guarded access. CPU workers
handle contention just as GPU workers do. Guard methods use no block/warp
barrier, named barrier, `mbarrier`, MAX `Semaphore`, or Cooperative Groups
operation. Ordered execution boundaries remain the global phase mechanism.
Collectives and async pipelines need a separate API and design.

Kernel synchronization declarations use `SyncRead`, `SyncWrite`, `AtomicRead`,
and `AtomicUpdate`. The conceptual accessor `context.sync.get[slot]()` yields
the permitted view; slot specifications are part of the compile-time kernel
signature and allow repeated payload types. Resource and captured owners use
the same binding adapter. Ordinary resource getters and `ReadCapture` /
`MutCapture` bindings cannot bypass protection of those owners during execution.

For example, a synchronized-write view attempts `try_write()`, updates two
related fields through the acquired guard, and releases it. The same source
handles `Busy` on either target. An atomic-update view increments a counter with
`fetch_add(1)`. These describe the intended API, not existing compilable examples.

### Protected values and access capabilities

Use a `Synchronized[T]` owner for a value requiring guarded access.
The payload is private. A kernel receives a non-owning view whose permission is
declared as synchronized-read or synchronized-write. Read permission permits
only acquisition of immutable guards; write permission permits either guard.
An outer read-only declaration must not accidentally grant interior mutation.

| Active access to one protection domain | Another read guard | Another write guard |
| --- | --- | --- |
| None | Allowed | Allowed |
| One or more read guards | Allowed | Contended |
| One write guard | Contended | Contended |

The interface is `try_read()` / `try_write()`, returning a movable, noncopyable
`TryAccess[Guard]` containing an acquired scope-bound guard or `Busy`. Extracting
an acquired guard consumes the result. A read guard lends an immutable
reference; a write guard lends a mutable reference. Acquisition either succeeds or reports contention
without waiting for another worker. References must end before guard release;
guards cannot be copied, sent to another worker, or escape the kernel invocation.
Scope exit releases once, including supported error paths. Destruction during
process/device failure is not a recovery guarantee.

There is no read-to-write upgrade, recursive acquisition, or fairness guarantee
in the first API. Release a read guard before attempting a write guard and
revalidate anything read earlier. A failed acquisition leaves payload unchanged.
An error after mutation releases protection but does not roll back mutations.

`Busy` can mean an incompatible guard, a state change during the attempt, or
reader-count saturation; it does not promise a writer is present. Each attempt
issues at most one compare-exchange, without a hidden retry loop. Failure grants
no payload access. Scope exit or an explicit consuming release ends the guard;
release cannot coexist with a live payload reference.

Illustrative use: acquire a read guard on shared configuration, inspect several
fields consistently, then release it. For a compound update, acquire a write
guard, update all related fields, and release it before doing unrelated work.
A plain read is still an access: it cannot bypass protection merely because it
does not write.

Protect independently mutable struct fields with separate owners. Protect
fields that form one invariant with the same owner. Do not offer a general
"lock this pointer" operation: separately locking overlapping pointers would
give the same bytes unrelated locks. Protected ownership includes reachable
mutable storage, or each reachable allocation must have its own explicit
protection/immutable contract; guarding a descriptor alone is insufficient.

### Fine-grained collections

Use stable, preallocated protection domains with explicit mapping:

- **Arrays:** one domain per element, fixed chunk, or user-selected stripe.
  Every access to an element maps to the same domain. Stripes reduce metadata
  but can cause unrelated elements to contend. Length, allocation, and mapping
  are fixed during execution; no resize or relocation is allowed.
- **Dictionaries:** begin with frozen topology and guarded values. Later permit
  insertion/removal through independently owned shards only after defining a
  concurrent container and device representation. A normal `Dict` does not
  become concurrent by attaching locks to its keys: probing, capacity, and
  allocation metadata may be shared by different keys.
- **Disjoint partitions:** permit ordinary mutable access when the executor or
  an exclusive partition capability establishes nonoverlap. A user assertion
  or raw pointer is not a safe proof. Unique entity-row iteration is the existing
  example and should not acquire a lock on every component access.

Default to one state per array element; fixed chunking/striping is chosen at
owner construction. `element(index)` validates bounds before acquiring access
and uses the owner's mapping even through subviews. Atomic arrays use separate
atomic scalar cells without reader/writer states. Frozen dictionary lookup
resolves a key to its stable value slot; missing keys are distinct from `Busy`.

A view may restrict accessible elements without creating new lock identities.
Overlapping views share the owner's domain mapping. Multi-element operations
acquire the distinct domain IDs in canonical order, deduplicate repeated IDs,
and release acquired guards if any acquisition fails before modifying data.
Provide a helper for this protocol rather than require users to reproduce it.
Whole-array reads and snapshots acquire all relevant domains or occur at a
quiescent execution boundary; a separate whole-array lock does not exclude
element writers unless an explicit hierarchy connects them.

Iteration over a frozen dictionary may acquire each value separately, but this
does not provide a consistent snapshot of all values. Whole-container structure
changes remain outside kernels in the initial scope.

### Atomic scalars

Provide an `AtomicValue[T]` owner and atomic-read / atomic-update views.
The initial scalar types are `UInt32` and `Int32`; state words use `UInt32`.

| Operation | Return behavior | Allowed orders; default |
| --- | --- | --- |
| `load` | Observed value | Relaxed or acquire; relaxed |
| `store(value)` | No value | Relaxed or release; relaxed |
| `fetch_add(delta)`, `fetch_sub(delta)` | Previous value | Relaxed, acquire, release, or acquire-release; relaxed |
| `compare_exchange(expected, desired)` | Success flag and observed value | Same success orders as RMW; relaxed default; relaxed failure order |

Ordering is a compile-time option mapped explicitly to Mojo constants.
Compare-exchange is strong (`weak=False`): success means an indivisible match
and replacement; its observed value equals `expected`. Failure returns the
value used by the comparison without modifying the scalar through that call.
The observed value is not a stable snapshot after completion. Arithmetic wraps
at the scalar width; checked arithmetic needs an explicit CAS protocol.

Defer `exchange`, min/max, bitwise RMWs, floating-point, and wider types until
common return semantics and backend support are validated. Do not implement the
initial API through unbounded CAS loops or private upstream `_xchg`. Atomic-read
permission permits loads only. No ordinary mutable reference to the scalar is
available while execution is active.

A shared counter uses `fetch_add(1)`. Loading and subsequently storing an
increment is two operations and can lose updates. Compare-exchange loops must
recompute from the observed value and must not perform externally visible side
effects on failed attempts. Atomic updates do not protect adjacent fields or
make a multi-field transaction. Floating-point accumulation may vary with
worker order; atomicity does not imply deterministic numerical results.

Translate every order explicitly rather than inherit target-dependent upstream
defaults.
Use relaxed ordering for independent counters; expose acquire loads, release
stores, and acquire-release read-modify-write operations for publication where
the backend supports them. A publication protocol still needs valid payload
ownership/lifetime and cannot use a flag to justify concurrently rewriting data
being read. Treat atomic and guarded payload access as separate modes during an
invocation; switching modes requires a quiescent boundary.

### Reader/writer state protocol

Each domain has one aligned, private 32-bit atomic word. Zero means unlocked;
1 through `0x7fffffff` count readers; `0x80000000` denotes one writer. No valid
state contains both a writer bit and a reader count.

| Action | Atomic protocol |
| --- | --- |
| `try_read` | Relaxed-load state; reject writer or maximum readers; one strong CAS from observed state to state + 1, acquire success and relaxed failure |
| `try_write` | One strong CAS from 0 to writer bit, acquire success and relaxed failure |
| Read release | Atomic subtract 1 with release ordering |
| Write release | Atomic store 0 with release ordering |

Successful CAS is the acquisition's linearization point. Reader increments and
decrements remain RMW operations, preserving release sequences for subsequent
acquisitions. An acquiring CAS observes writer publication directly or through
intervening reader RMWs. Prove these properties on each backend, including the
last-reader-to-writer transition. A relaxed load observing zero grants no access.

Initialize state before publishing the owner. Only guard internals change it
during execution; no ordinary stores, mid-execution resets, or live-state copies.
Reader saturation returns `Busy` without overflowing. Balanced release prevents
underflow. No queued-writer bit is used, so sustained readers can starve writers;
workload retries must have an exhaustion policy.

### CPU and GPU semantics

Use the same guard/atomic interfaces in the kernel body, with backend operations
selected during compilation. Host synchronization must use real atomics even
while the executor is sequential; lock elision is deferred. Device
protection defaults to device-wide scope for globally shared resources; a
block-only primitive cannot protect data accessed by other blocks.

The host adapter uses the CPU scope covering all host workers (default/system
CPU scope, to be verified against the locked compiler). The device adapter selects
whole-device scope, using Mojo's `device` scope where supported. Preserve each
pointer's target address space and natural alignment. Scope strings and compiler
lowering remain internal; do not pass a GPU-only scope string to the CPU adapter.

Guard acquisition provides acquire visibility and release provides release
visibility for the protected payload. The selected state protocol still needs
proof and backend tests. Never substitute relaxed lock operations without a
verified payload visibility mechanism. Unsupported type/operation/ordering/scope combinations
must fail clearly rather than silently weaken the contract.

No standalone fence is exposed or required by the first guard API: acquire/
release atomics supply its synchronization. Subgroup barriers and `syncwarp`
cannot replace them. A target can support relaxed scalar operations while
rejecting guards or publication orders until those stronger semantics are
proven. The same source must work across supported targets; unsupported
guarantees cannot be emulated with weaker operations.

GPU scheduling does not provide a general portable guarantee for arbitrary
blocking mutex algorithms. The initial common API therefore has no blocking
`read()` / `write()`, unlimited spin retry, lock upgrade, or barrier inside a
guarded section. A failed try must have an explicit outcome: deferred work,
bounded retry followed by reporting, or an application-approved skip. Work
requiring every update must retain failed work and retry at a later execution
boundary, with an exhaustion policy; silently dropping it is incorrect. Deferred
processing is not automatically supplied by the current executor.

This is memory synchronization, not a grid barrier. Do not insert block
barriers into arbitrary entity loops: workers may visit different row counts.
Global phases use separate launches / host execution boundaries. A future
collective API needs its own participation and launch contract. Nonblocking
acquisition bounds waiting for another worker, but does not imply bounded total
kernel time or fairness for repeated attempts.

### Binding, transfer, and lifetime

An owner cannot be copied while active. Views may share one storage identity;
copying a view must never copy its payload or lock state. The current
`ResourceType`/capture `Copyable` constraints and untracked accessor origins are
implementation obstacles, not proof that these owner/guard types already fit.
First validate guard-bound origins and binding adapters. If Mojo cannot enforce
reference confinement, use scoped callbacks or restricted operations; do not
label an unrestricted reference API safe.

For each synchronous invocation, keep payload allocations and domain mapping
stable until all workers complete. Share one host sidecar across all matching
ranges and one device sidecar across the packed launch. Device synchronization
state starts unlocked, is checked as released on successful completion, and is
not copied back as user data. Copy back payload according to declared writes
after completion. Reject overlapping protected/raw bindings and unsupported
aliases; do not upload the same owner into independent mutable device copies.

Host and device copies are separate execution domains under decision 0002;
this design does not enable simultaneous CPU/GPU access to one allocation.
Collections still require the heap-backed transfer design before device use.
Structurally moving ECS data, resizing containers, and spatial maintenance
cannot occur while synchronization views remain active. Future concurrent
kernel launches or CPU systems must share protection identity or reject
conflicting invocations; per-invocation sidecars alone are insufficient then.

## Rationale

Scoped guards express shared reads and exclusive writes for compound invariants.
Atomics avoid serializing simple scalar updates through a compound-data lock.
Stable domain mapping supports fine-grained protection without pretending that
independent logical keys always occupy independent physical storage. Existing
immutable and uniquely owned row accesses preserve their current low overhead.

Blocking CPU reader/writer locks may be a useful future host-specific extension,
but cannot establish the portability contract for device kernels. Lock-free
containers, transactional memory, arbitrary overlapping range locks, concurrent
resizing, and unified host/device coherence are outside this initial design.

## Consequences

This adds declarations and owner/view binding work; it does not retrofit thread
safety onto current mutable resources or captures. Contended kernels must define
how work completes. Fine-grained domains trade metadata and cache traffic for
less contention; read-heavy code may still pay atomic reader-count costs.

Before implementation ships, validate confinement in the current Mojo
origin system and publish a CPU/NVIDIA/AMD/Apple capability matrix from compile
probes and actual hardware runs. Start with the specified 32-bit atomic operations,
then single-value guards, fixed arrays, and frozen dictionary values. Concurrent
dictionary topology requires a subsequent design. Keep priorities in the roadmap.

Validation must cover reader coexistence, reader/writer and writer/writer
exclusion, publication visibility, exact atomic totals, contention outcomes,
scope/error cleanup, forbidden reference escape, duplicate/overlapping bindings,
collection mapping, and host/device payload preservation. Single-threaded host
tests cannot prove concurrent correctness; skipped GPU tests are not evidence.
Representative measurements should compare immutable/disjoint controls, atomics,
and guards under low/high contention with identical work and preserved results.
Report sidecar setup and transfer costs separately and in complete execution.

## Evidence

- `src/larecs/sync.mojo` implements noncopyable owners, borrowed views, consuming
  acquisition results, and guard-confined references. CPU coverage is in
  `test/synchronization_test.mojo` and negative compiler checks in
  `test/check_synchronization_contracts.py`; the complete test runner executes
  those checks. Explicit move/destruction on views prevents their direct or
  aggregate raw-byte resource/capture transfer; `test_views_cannot_use_raw_device_transfer`
  verifies the predicates used at those existing boundaries.
  `test/gpu_synchronization_test.mojo` has actual-hardware tests
  with explicit skip messages. [User guide](../../src/guide/synchronization.md)
  documents the implemented slice and unsafe device adapters.
- On Linux x86_64, Mojo 1.0.0 (`ed45d567`) / MAX 26.5.0, host behavior was
  exercised with four actual CPU workers. Device compile probes use `mojo build
  --target-accelerator <target> --emit asm`; executable-only builds can retain
  deferred GPU IR and do not establish backend lowering success. NVIDIA `sm_80`
  uses `device` scope, while AMD `gfx942` requires `agent` scope. LLVM documents
  [AMD synchronization scopes](https://llvm.org/docs/AMDGPUUsage.html#memory-scopes).
  Apple `apple-m4` permits compilation of the relaxed scalar slice; the locked
  compiler rejects strong CAS. Guards, strong CAS, and non-relaxed public scalar
  orderings are explicitly rejected there. GPU hardware was unavailable on the
  local runner; compilation is not evidence of runtime correctness.
- The focused `benchmark/synchronization_benchmark.mojo` compares ordinary
  increments, direct upstream atomics, Larecs atomic views, and uncontended write
  guards. It validates totals and excludes setup from timing; no application
  speedup or contended-device performance claim is established.

- [GPU synchronization research](../research/gpu-synchronization.md) compares
  Mojo, MAX, and NVIDIA primitives, including collective participation,
  semaphore semantics, backend differences, and publication requirements.

- Current contracts: [ECS-05 and ECS-08 through ECS-10](../requirements.md),
  [device execution](0002-gpu-system-execution.md), and
  [grid-stride iteration](0003-grid-stride-entity-iteration.md).
- Current implementation: `src/larecs/lock.mojo`, `resource.mojo`, `capture.mojo`,
  `system.mojo`, and `iteration.mojo`; [resource guide](../../src/guide/resources.md)
  describes shared resource writes and raw-byte transfer limits.
- [Mojo 1.0.0 Atomic reference](https://mojolang.static.modular.com/1.0.0/docs/std/atomic/atomic/Atomic/)
  exposes ordering and scope parameters and target-dependent defaults. This is
  API evidence, not validation of every operation on every backend.
- [NVIDIA advanced kernel programming](https://docs.nvidia.com/cuda/cuda-programming-guide/03-advanced/advanced-kernel-programming.html)
  documents scheduling-related lock deadlock hazards. The portable nonblocking
  policy above is a Larecs design inference, not a claim about all GPU hardware.
- Binding/collection implementation and GPU hardware evidence remain pending; see the
  [synchronization roadmap](../../roadmap.md#kernel-memory-synchronization).
