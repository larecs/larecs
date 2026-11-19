---
id: "0017"
title: "Deferred kernel access"
status: proposed
status_notes: |
  Waiting API proposal; executor queues, callback binding, and retry execution
  are not implemented. Does not supersede the accepted nonblocking primitives
  in decision 0016. API expressions are illustrative, not compilable Mojo.
---

# Decision 0017: Deferred kernel access

## Context

[Decision 0016](0016-kernel-memory-synchronization.md) returns `Busy` when a
guard cannot be acquired. Users also need an ergonomic way to ensure required
operations eventually execute without writing retry machinery in every kernel.
The common CPU/GPU API cannot assume that suspending or indefinitely spinning
an arbitrary GPU thread permits every dependency to make progress.

## Decision

Propose executor-managed deferred access on top of the existing try primitives.
Waiting means retaining an operation until a later attempt can acquire access;
it does not suspend a kernel stack or hold a GPU thread in a wait loop.

### Scoped operations

Provide conceptual `context.sync.with_read[operation](view, arguments)` and
`context.sync.with_write[operation](view, arguments)` calls. `operation` is a
compile-time, noncapturing callable; `arguments` is an explicit owned payload
with a supported host/device representation. Read/write capabilities follow
decision 0016. The operation receives the acquired immutable/mutable guarded
access, and its reference cannot escape. The executor releases the guard when
the operation ends. Both targets use the same source and behavior.

Attempt access once. If acquired, execute the operation immediately. If busy,
retain the operation description in an invocation-owned bounded queue. Return
`Completed` or `Deferred`; neither outcome means that dependent code outside
the operation can assume its result is available. Queue overflow records a
required-work failure and makes the enclosing run fail; it never drops work
silently. Deferred calls are allowed only when the enclosing run is configured
to own and drain this queue.

For example, put an inventory decrement and the computation that depends on
the new inventory value in one write operation. If access is unavailable, that
whole operation is retried later. A following ordinary kernel statement does
not wait automatically. Store outputs in declared per-operation result storage
or permitted components and consume them in a subsequent execution phase.

Do not provide synchronous result-returning `read()` / `write()` or device
`await` as aliases for this API. Making a normal call transparently resume its
entire caller later would require a separate continuation transformation.

### Queue and execution boundaries

Allocate the queue before launch, with explicit operation-count capacity and
an invocation-wide maximum number of retry passes. Queue slots are reserved
atomically. Records identify the callable specialization, protection domain,
owned arguments, output slot, and pending state; publication must be complete
before retry consumers read records. An ordered launch boundary can establish
that completion for the initial implementation.

After the initial workers complete and release all guards, the executor processes
only pending operations. Host execution uses the same pass structure; device
execution uses ordered retry launches. Each pass tries once per pending record,
retains failures, and retires completed records. Never rerun the original entity
kernel: it may already have changed components or emitted other side effects.

One queue consumer owns each record per pass. A callback is invoked only after
successful acquisition and is never retried after it begins. A callback error
releases its guard, records failure, and is propagated without replaying partial
effects. This gives at-most-once callback invocation, not transaction rollback.
When every required operation succeeds, `run` may complete successfully. When
the retry limit is exhausted, `run` reports incomplete work rather than success.
Earlier effects remain; retrying the complete run is not automatically safe.

Initially forbid nested deferred submissions, acquiring other guards, barriers,
and waiting for another queued operation inside callbacks. Operations must be
finite and independent apart from contention on their declared domain. FIFO
fairness and deterministic callback order are not promised. Guaranteed completion
would need an additional scheduler policy, such as serializing pending operations
per domain; bounded retry alone cannot promise it.

### Ownership and transfers

Keep owners, mappings, pending records, and outputs alive until queue draining
or failure cleanup completes. Preserve protection identity throughout the
invocation. Deferred records cannot contain guard references, stack borrows,
raw entity accessors, or host pointers masquerading as device pointers.
Heap-backed arguments need the separately designed transfer representation.

For entity outputs, bind an executor-validated row/output token while structural
changes are forbidden; reacquire an accessor for that row in the operation
instead of retaining a borrowed accessor. Output writes must be disjoint or use
their own declared synchronization protocol. Unsupported bindings fail before
launch. Device retry passes use the same target-local payload buffers; copy-back
happens only after draining or the defined failure boundary, following existing
execution error guarantees. Partial copy-back behavior must be specified and
tested before this proposal is accepted.

## Rationale

Scoped operations package the guarded access and its dependent computation in
a form the executor can safely retain. Retry launches give GPU scheduling a
completion boundary between attempts. A CPU-specific blocking guard could be
added separately, but would not have the same semantics in portable kernels.

## Consequences

This adds queue storage, operation dispatch, output binding, error propagation,
and retry-launch cost. It changes when required operations finish relative to
the ordinary kernel body. It leaves `try_read` / `try_write` unchanged and
therefore does not supersede decision 0016. Exact signatures and bounded device
dispatch need compile probes before acceptance.

Validate no lost/duplicated work, queue saturation, publication, retry exhaustion,
partial-error cleanup, reference confinement, and unchanged CPU/GPU results.
Measure contention and complete execution including queue setup and retry passes.
Keep planned work in the [roadmap](../../roadmap.md#kernel-memory-synchronization).

## Evidence

- [Synchronization research](../research/gpu-synchronization.md) distinguishes
  collective waiting, memory ordering, ownership, and GPU progress constraints.
- [Decision 0016](0016-kernel-memory-synchronization.md) defines the accepted
  atomic state protocol and nonblocking acquisition interface.
- `src/larecs/system.mojo` currently has synchronous host/device execution;
  it does not implement an invocation-owned deferred-operation queue.
