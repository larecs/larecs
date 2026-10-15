---
id: "0019"
title: "Threaded host execution"
status: proposed
status_notes: |
  Design interview in progress. Contiguous chunking and the execution boundary,
  runtime budget, initial safety scope, explicit activation, chunk semantics,
  fallback, eligibility errors, and world confinement are agreed; remaining
  choices below are unresolved. No production engine is implemented or
  authorized by this record.
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
- Initially support thin, component-only kernels over validated value components.
  Reject unsupported shared state. Shared resources and captures require later
  explicit immutable or synchronized bindings; existing mutable bindings do not
  become thread-safe. Dedicated bindings under decision 0016 remain unfinished.
- Require explicit threaded selection for each `run`; existing calls remain
  sequential. Worker configuration alone does not activate threaded execution.
- Row indices are local to a chunk; chunk order is unspecified. Code outside
  the entity loop runs once per chunk. Kernels cannot assume whole-archetype
  invocation or ordering between chunks. Cross-chunk dependencies require a
  subsequent synchronous `run`.
- Permit sequential dispatch for small workloads, using the same threaded-engine
  eligibility checks before choosing that performance fallback. The worker count
  is an upper bound, not a minimum utilization guarantee.
- Reject unsupported components, resources, and captures before modifying any
  row. Eligibility errors do not silently select the sequential engine; this
  differs from the performance fallback for an eligible kernel.
- Require one coordinating caller per world. Initially prohibit reentrant
  execution and world mutation from workers; workers receive prepared chunk
  contexts. Structural locks alone do not arbitrate concurrent external callers.

The user affirmed the execution boundary, runtime budget, and initial safety
scope in interview answers Q1–Q3, and affirmed explicit activation, chunk
semantics, validated fallback, pre-write eligibility errors, and world
confinement in Q4–Q8. Contiguous chunks and iterator reuse were agreed before
those rounds. The complete decision remains proposed until the
remaining branches are resolved and the user confirms shared understanding.

Unresolved choices:

- Engine ownership/configuration, opt-in syntax, and interaction with `on_device`.
- Chunk sizing, fallback cutoff, and configuration validation.
- Exact component eligibility and rejection diagnostics.
- Configuration copying and lifecycle behavior, and confinement enforcement.
- Preparation/dispatch failures, partial effects, and completion guarantees.
- Production validation coverage and promotion of the proposal to requirements.

## Rationale

Contiguous chunks expose parallelism within one store while retaining sequential
row access. Synchronous completion provides an ownership and visibility boundary.
A shared runtime avoids designing a dedicated thread pool. Restricting initial
bindings avoids promising safety from incomplete synchronization integration.

## Consequences

The concurrency budget limits submitted worker tasks rather than reserving CPU
cores. Kernel source portability does not imply eligibility for every engine;
changing workload size cannot make an ineligible threaded kernel valid. Existing
kernel side effects outside the entity loop can observe a change in invocation
count when callers explicitly select the threaded engine.
The existing accepted requirements remain in force; ECS-09 needs clarification
about sequential iteration within concurrent host jobs before adoption.

## Evidence

- [Investigation and measured chunk comparisons](../research/host-thread-execution.md).
- [Host context preparation](../../../src/larecs/system.mojo) and
  [entity iteration](../../../src/larecs/iteration.mojo).
- [Kernel synchronization](0016-kernel-memory-synchronization.md),
  [grid-stride iteration](0003-grid-stride-entity-iteration.md), and
  [current requirements](../requirements.md).
- [Roadmap](../../roadmap.md) tracks implementation separately from this proposal.
