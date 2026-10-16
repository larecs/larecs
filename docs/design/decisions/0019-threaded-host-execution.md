---
id: "0019"
title: "Threaded host execution"
status: accepted
status_notes: |
  Experimental implementation adopted. Linux correctness and concurrency are
  validated; macOS arm64 correctness, concurrency, and performance remain pending.
---

# Decision 0019: Threaded host execution

## Context

Whole-store jobs cannot parallelize a world dominated by one archetype.
Contiguous chunks reuse existing host contexts and entity iteration, but change
invocation granularity and require explicit resource-sharing and lifetime rules.

## Decision

### Selection and dispatch

Add a compile-time `threaded=True` option to both `SystemContext.run` and
`EntitySelection.run`. Keep `on_device`; reject selecting both before hardware
fallback or row processing. Existing calls remain sequential with their current
whole-store or exact selected-range invocation behavior.

For an eligible threaded invocation, select dispatch as follows:

| Condition | Dispatch |
| --- | --- |
| No matching rows | No kernel invocation. |
| Below the parallel cutoff, or one configured worker | Existing whole-range sequential dispatch after threaded eligibility checks. |
| Otherwise | Contiguous chunk jobs on MAX's shared CPU runtime. |

Only parallel dispatch introduces chunking. Split each matching physical store
or saved selected range independently, without crossing store boundaries or
bridging unselected gaps, including partitioned storage. Prepare contexts with
`_host_kernel_context` and reuse `EntityAccessorIterator` unchanged: offset
component pointers to each chunk's start, set its exact length, and iterate with
host stride one. Workers dynamically claim nonoverlapping jobs; each eligible
row executes exactly once.

Every run is synchronous. Join all workers before releasing storage/bindings,
returning, or starting the next kernel/system. Preserve sequential system and
kernel-call order; asynchronous submission and concurrent systems are excluded.

Chunk order is unspecified, indices are chunk-local, and code outside the entity
loop runs once per chunk. Whole-range sequential fallback uses whole-range local
indices and invocation counts. Consequently, changing the cutoff can change
invocation counts and index resets for explicitly threaded calls. Kernels must
tolerate that granularity; cross-chunk dependencies require a subsequent run.

### Configuration

Store immutable runtime configuration on `World`, supplied at construction:

| Setting | Default | Constraint |
| --- | ---: | --- |
| Worker-task budget | 1 | Positive. |
| Target chunks per worker | 4 | Positive. |
| Minimum matched rows for parallel dispatch | 65,536 | Nonnegative; zero disables the row cutoff. |

Use deterministic chunk sizing rather than automatic tuning. Configuration
changes scheduling, not kernel eligibility. The cutoff is a conservative initial
policy from one machine's measurements, not a portable performance guarantee.
Worker configuration alone never activates threaded execution.

The budget bounds submitted worker tasks; MAX owns the shared runtime. It does
not reserve CPU cores, guarantee simultaneous execution, or create a dedicated
pool of persistent OS threads. Idle world copies/moves preserve configuration
without duplicating a pool.

### Components, resources, and kernels

Initially accept nonraising thin kernels with these bindings:

- Validate only accessed component types. Admit scalar/SIMD values and recursively
  validated plain-value structs; reject accessed pointer-bearing, owning-container,
  and opaque types until a supported ownership/synchronization contract exists.
  Types conforming to the `PlainValue` marker declare a pointer-free opaque
  representation, such as a `StaticTuple` of scalars, and are admitted when
  trivial; the declaring author is responsible for that claim.
  Unaccessed components do not prohibit threading.
- Admit ordinary resources with explicit read access when their types pass the
  pointer-free value validator. Scalar parameters do not need adapters.
- Admit shared read-only adapted resources through the existing `KernelView`
  design. The component pointer restriction does not reject adapter-managed
  immutable pointers in resource views.
- Reject all write/read-write resource declarations, including legacy mutable
  defaults, and explicit captures. Lexical closure kernels are unsupported.
  Dedicated synchronization bindings under decision 0016 remain unfinished.

Every resource adapter must support concurrent reads of its `KernelView` on the
view's execution target. This is a documented adapter contract, with no optional
capability marker. View methods and reachable data must permit concurrent reads
without hidden unsafe mutation; structural descriptor checks cannot prove this.

Validate and bind each adapted source once on the coordinating caller before
any kernel writes. All jobs share the same host descriptor and backing data;
do not copy resource owners or sample buffers per worker. Retain source leases
and invocation-owned descriptors until all workers finish, including fallback.

All reachable resource data must remain valid and safe for concurrent reads
throughout execution. No alias may mutate, resize, relocate, or free it, including
aliases through writable components. Immutable pointer fields and source leases
do not prove this for arbitrary adapters or escaped references. Writable sharing
requires a later synchronization design.

Kernel authors must avoid mutable globals and non-thread-safe callees. Thin
signatures and value validation do not establish full thread safety for arbitrary
kernel implementations.

### Isolation and failure

Require one coordinating caller per world. Workers receive prepared contexts;
reentrant execution and worker access that mutates the world are prohibited.
Structural locks alone do not arbitrate concurrent external callers.

Prohibit copying, moving, replacing, or destroying an executing world. Enforce
tracked borrows where possible; detected lifecycle violations through escaped
aliases must fail unconditionally rather than invalidate worker pointers.

Validate threaded eligibility before selecting fallback. Unsupported bindings
produce errors rather than silently selecting sequential execution. Finish all
fallible context/binding preparation before dispatch so recoverable preparation
errors leave rows untouched. Fatal MAX worker/runtime failures have no recovery
or rollback guarantee; recoverable worker exceptions are outside initial scope.

### Validation

Before advertising production support on both platforms, validate correctness
and actual concurrency on Linux x86-64 and macOS arm64. Cover shared-resource
lifetimes, exact selections, partition stores, fallback behavior, lifecycle
violations, and rejected inputs. Measure performance on both without requiring
a fixed speedup. Keep support experimental wherever validation is incomplete.

The public configuration is `ThreadedExecutionConfig(workers=1,
chunks_per_worker=4, min_parallel_rows=65_536)`, supplied to
`World(execution_config=...)`; its no-argument constructor supplies the defaults.
Settings are returned by value through `World.execution_config()`. Custom
configuration construction raises on invalid bounds or chunk-target overflow.
Row totals, range bounds, context lengths, and terminal atomic claims use
checked arithmetic before dispatch.

## Rationale

Chunks expose parallelism within one store while retaining contiguous access.
Explicit selection preserves sequential compatibility. Whole-range fallback
avoids introducing chunking into the existing sequential runtime. Synchronous
completion bounds borrowed lifetimes, and a shared runtime avoids pool ownership.

Value-only components and shared read-only resource views provide a restricted
initial safety boundary. A universal concurrent-read adapter contract preserves
the existing view abstraction without adding another capability hierarchy.

## Consequences

Sequential behavior stays unchanged. Explicit threaded calls can observe changes
in invocation granularity as workload size or scheduling settings change.
Eligibility remains constant across parallel and sequential fallback paths.

This decision extends decision 0018 with concurrent-read adapter obligations.
The built-in buffer adapter shares immutable sample memory without hidden
mutation. Third-party adapters must audit view methods and reachable data.
ECS-09 and ECS-18 distinguish sequential iteration within a job from concurrent
host jobs. Existing sequential invocation boundaries remain unchanged.

## Evidence

- Implementation: `src/larecs/execution.mojo` and the shared `_run_threaded`
  preparation/dispatch path in `src/larecs/system.mojo`.
- [Correctness and actual concurrency](../../../test/threaded_execution_test.mojo),
  [eligibility and lifecycle diagnostics](../../../test/check_threaded_contracts.py),
  [complete-call benchmark](../../../benchmark/threaded_execution.mojo), and
  [Linux implementation measurements](../../src/guide/benchmarks.md#threaded-host-execution).
- [Investigation and measurements](../research/host-thread-execution.md).
- [Host contexts and dispatch](../../../src/larecs/system.mojo),
  [entity iteration](../../../src/larecs/iteration.mojo), and
  [recursive value validation](../../../src/larecs/resource_representation.mojo).
- [Grid-stride iteration](0003-grid-stride-entity-iteration.md),
  [kernel synchronization](0016-kernel-memory-synchronization.md), and
  [portable resource adapters](0018-portable-resource-adapters.md).
- [Current requirements](../requirements.md) and [roadmap](../../roadmap.md).
