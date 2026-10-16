---
id: "0019"
title: "Threaded host execution"
status: proposed
status_notes: |
  Design interview in progress. Contiguous chunking and the execution boundary,
  runtime budget, initial safety scope, explicit activation, chunk semantics,
  fallback, eligibility errors, world confinement, configuration ownership,
  selector compatibility, hidden-state obligations, and initial failure handling
  are agreed. Value-only components, ordinary value-only read resources, and
  shared read-only KernelView resources are in scope. Concurrent reads are an
  adapter contract, not an optional capability. Ordinary and selected execution
  and configurable scheduling are in scope. Remaining choices below are
  unresolved. No production engine is implemented or authorized by this record.
---

# Decision 0019: Threaded host execution

## Context

Whole-store jobs cannot parallelize a world dominated by one archetype.
Contiguous chunks reuse existing host contexts and entity iteration, but affect
invocation counts, shared access, and scheduling semantics.

## Decision

The following choices are settled in the design interview:

- Split matching physical-store or exact selected ranges into nonoverlapping
  contiguous chunks. Prepare each chunk through `_host_kernel_context` and
  reuse `EntityAccessorIterator` unchanged. Each host job iterates with stride one.
- Parallelize chunks within one synchronous `run`. Join all chunks before
  returning; retain sequential system and kernel-call order. Concurrent systems
  and asynchronous submissions are outside the initial engine.
- Use MAX's shared CPU runtime with a configurable worker-task concurrency
  budget fixed for the engine's lifetime. The budget does not promise ownership
  of that many persistent OS threads or simultaneous execution on all workers.
- Initially support thin kernels over validated value components and include
  shared read-only resources through the existing `KernelView` adapter design.
  This expands the earlier component-only scope. Explicit captures and writable
  shared resources remain outside the initial scope; dedicated synchronization
  bindings under decision 0016 remain unfinished.
- On the coordinating caller, validate and bind each adapted source once before
  dispatch. All chunk accessors reference the same host view and backing data;
  do not copy resource owners or sample buffers per worker. Retain source leases
  and invocation-owned view descriptors until all workers join, including when
  an eligible invocation uses sequential performance fallback.
- All data reachable through a shared view must remain valid and safe for
  concurrent reads throughout the invocation. No alias may mutate, resize,
  relocate, or free that data, including writable component aliases. Immutable
  pointer fields and source leases do not prove this contract for arbitrary
  adapters or escaped references. Writable sharing requires a later explicit
  synchronization design.
- Admit ordinary resources declared with explicit read access when their types
  pass the pointer-free value validator. Scalar parameters do not require an
  adapter. Reject every write/read-write resource declaration, including legacy
  mutable defaults, in the initial threaded engine.
- Every resource adapter must support concurrent reads of its `KernelView` on
  the view's execution target under the frozen-data contract. Document this as part of `ResourceAdapter`'s
  contract; do not introduce a separate opt-in trait or capability flag. View
  methods and reachable data must permit concurrent reads without hidden unsafe
  mutation. Structural descriptor validation alone cannot prove this guarantee.
- Validate only component types accessed by the kernel. Accept scalar/SIMD values
  and recursively validated plain-value structs; reject accessed pointer-bearing,
  owning-container, and opaque component types until a supported ownership or
  synchronization contract exists. An unrelated unaccessed component does not
  prohibit threading. This component rule does not prohibit adapter-managed
  immutable pointers in resource `KernelView` descriptors.
- Require explicit threaded selection for each `run`; existing calls remain
  sequential. Worker configuration alone does not activate threaded execution.
- Row indices are local to a chunk; chunk order is unspecified. Code outside
  the entity loop runs once per chunk. Kernels cannot assume whole-archetype
  invocation or ordering between chunks. Cross-chunk dependencies require a
  subsequent synchronous `run`.
- Permit sequential dispatch for small workloads, using the same threaded-engine
  eligibility checks before choosing that performance fallback. The worker count
  is an upper bound, not a minimum utilization guarantee.
- Expose a configurable minimum matched-row count for parallel dispatch and a
  target number of chunks per worker. Start with a target of four chunks per
  worker; use deterministic policy rather than automatic tuning. These settings
  change scheduling, not kernel eligibility. The default row cutoff is unresolved.
- Support both ordinary `SystemContext.run` and exact `EntitySelection.run`,
  including spatially partitioned physical stores. Split each matching store or
  saved selected range independently without crossing store boundaries or
  bridging unselected gaps. Visit every eligible selected row exactly once.
- Reject unsupported components, resources, and captures before modifying any
  row. Eligibility errors do not silently select the sequential engine; this
  differs from the performance fallback for an eligible kernel.
- Require one coordinating caller per world. Initially prohibit reentrant
  execution and world mutation from workers; workers receive prepared chunk
  contexts. Structural locks alone do not arbitrate concurrent external callers.
- Store threaded configuration on `World`, supplied at construction and immutable
  thereafter. Copying an idle world preserves the configuration; MAX retains
  ownership of its shared runtime rather than duplicating a pool per copy.
- Add a compile-time `threaded=True` option to `run`, retaining `on_device`.
  Reject selecting both before hardware fallback or row processing.
- Require threaded kernel implementations to avoid mutable globals and
  non-thread-safe callees. Thin function signatures and validated component
  representations cannot establish this obligation for arbitrary kernel code.
- Complete all fallible context preparation before dispatch. Preparation errors
  are recoverable without row writes; the initial engine retains nonraising
  kernels and offers no recovery or rollback guarantee for fatal MAX worker or
  runtime failures.

The user affirmed the execution boundary, runtime budget, and initial safety
scope in interview answers Q1–Q3, and affirmed explicit activation, chunk
semantics, validated fallback, pre-write eligibility errors, and world
confinement in Q4–Q8. Q9, Q10, Q12, and Q13 settled configuration ownership,
selector compatibility, hidden-state obligations, and initial failure handling.
The Q11 clarification settled component eligibility; the user additionally
requires resource sharing compatible with `KernelView`. Q14 settled shared
read-only views with frozen reachable data and invocation-wide bindings.
Q15 admitted ordinary value-only read resources. For Q16, the user requires every
adapter to support concurrent reads as a documented contract, without an opt-in
marker. Q17 and Q18 settled configurable scheduling and ordinary/selected API
coverage, including partitions. Contiguous chunks and iterator reuse were agreed
before those rounds. The complete decision remains proposed until the
remaining branches are resolved and the user confirms shared understanding.

Unresolved choices:

- Configuration type/constructor spelling, defaults, and validation.
- Exact deterministic chunk-sizing policy and default parallel cutoff.
- Adapter contract documentation and compatibility validation under decision 0018.
- Eligibility diagnostics and the neutral component-validator API.
- Active-world copy/move rules, lifecycle details, and confinement enforcement.
- Dispatch completion guarantees beyond the agreed initial failure boundary.
- Production validation coverage and promotion of the proposal to requirements.

## Rationale

Contiguous chunks expose parallelism within one store while retaining sequential
row access. Synchronous completion provides an ownership and visibility boundary.
A shared runtime avoids designing a dedicated thread pool. Restricting initial
bindings avoids promising safety from incomplete synchronization integration.
Making concurrent reads a universal adapter obligation preserves the existing
view abstraction without adding a second resource capability hierarchy.

## Consequences

The concurrency budget limits submitted worker tasks rather than reserving CPU
cores. Kernel source portability does not imply eligibility for every engine;
changing workload size cannot make an ineligible threaded kernel valid. Existing
kernel side effects outside the entity loop can observe a change in invocation
count when callers explicitly select the threaded engine.
The adapter contract extends decision 0018's read-only views with an explicit
concurrent-read obligation. Existing adapters need an audit of view methods and
reachable data; their ordinary read-only type signatures are not sufficient proof.
The existing accepted requirements remain in force; ECS-09 needs clarification
about sequential iteration within concurrent host jobs before adoption.

## Evidence

- [Investigation and measured chunk comparisons](../research/host-thread-execution.md).
- [Host context preparation](../../../src/larecs/system.mojo) and
  [entity iteration](../../../src/larecs/iteration.mojo).
- [Kernel synchronization](0016-kernel-memory-synchronization.md),
  [portable resource adapters](0018-portable-resource-adapters.md),
  [grid-stride iteration](0003-grid-stride-entity-iteration.md), and
  [current requirements](../requirements.md).
- [Roadmap](../../roadmap.md) tracks implementation separately from this proposal.
