---
id: "0012"
title: "Deferred spatial maintenance and conservative invalidation"
status: accepted
---

# Decision 0012: Deferred spatial maintenance and conservative invalidation

## Context

Decision 0008 proposes observing final values once per dirty entity. Decisions
0005 and 0010 unconditionally classify all eligible rows. Mutable references,
exact selected execution, component transitions, and GPU scatter writes prevent
setter-only tracking from being correct.

## Decision

Supersede decisions 0005 and 0010's full-scan-only contract, retaining their
single owned policy, read-only filter, checked unsigned keys, host classification,
structural locks, typed permutations, and lifecycle/failure guarantees.

Store invalidation state in `HostStorage`, alongside the mutation APIs exposed
through `World.storage`. Registration activates tracking and requests a full
rebuild. A dense queue stores full `Entity` identities, including generations;
a sparse Boolean membership array and cached UInt64 keys are indexed by ID.
Structural mutation requests a full rebuild before potentially changing storage,
including selected creation, in-place replacement, selection transitions, bulk
moves, deletion, and low-level `apply`. This conservative fallback bounds stale
key lifetime, covers eligibility transitions and ID recycling, and preserves
whole-archetype mutation fast paths. Failed structural requests may overinvalidate.
A rebuild replaces all keys and membership state; queue entries never store rows.

For ordinary mutations, mutable `HostStorage.get` exposure and both setter forms
mark overlapping classifier inputs. A read through a mutable reference also
marks; read-only queries do not. CPU thin and lexical kernels mark bounded
matching declared writable ranges before execution; selected execution preserves
exact ranges and kernel-filter intersection. GPU scatter invalidates potential
host writes before copy-back. Read-only/unrelated component declarations do not
mark. These are potential-write declarations, not value-change detection.

`HostStorage.mark_spatial_dirty(entity)` validates a live identity and deduplicates
explicit marking. `World.invalidate_spatial()` and the storage equivalent request
a full rebuild for untracked raw-pointer/archetype writes or external configuration
changes. No marking operation classifies or reorders, and marking is legal under
structural locks. Unsafe internal access cannot be intercepted automatically.
References and kernel accessors must not survive maintenance or execution respectively.

At `maintain_spatial`, reject structural locks even when clean or unregistered.
A clean registered call returns immediately. Otherwise resolve dirty identities
through current locations, check liveness and current filter eligibility, and
classify each matching identity once under the callback structural lock. A full
rebuild classifies all eligible rows. When all allocated ID slots are dirty,
maintenance also chooses contiguous full classification to avoid per-identity
column/location setup; holes and unmarked excluded entities delay this fallback.
This changes no eligible entity's required classification count. Build candidate keys in separate scratch,
check order only in affected archetypes, and prepare every permutation before
moving any components. Commit keys and clear invalidations only after successful
movement. Classifier errors retain committed keys and all invalidations for retry,
leave every row order unchanged, release the callback lock, and preserve the
original error. Allocation/lifecycle fatal failures retain decision 0009's limits.

Copied/moved worlds own independent keys, sparse membership, and pending queues
alongside their copied/moved policies. There is no automatic policy replacement,
multiple-policy resolution, background maintenance, or GPU classification.

## Rationale

Sparse membership makes marking amortized O(1) with no hashing in hot component
access paths; full identities protect queue entries from stale row addresses.
Structural rebuilds deliberately trade classification cost for simpler reliable
coverage of existing mutation engines. No special placement component or
interception of each individual reference write is necessary.

Candidate keys currently copy the ID-capacity array on nonclean passes to preserve
failure semantics. Ordering still scans affected archetypes and can move clean
entities. Reducing classifier calls to D therefore does not make complete
maintenance O(D). Dense writes can cost more than contiguous full classification;
applications can explicitly request rebuilds and select maintenance cadence.

## Consequences

Spatial tracking is opt-in; unregistered worlds retain no per-entity tracking
allocations. Registered worlds retain O(entity-ID capacity) keys and membership,
plus O(distinct dirty identities) queue capacity. Removed IDs' capacity can remain
allocated. Nonclean passes use O(ID capacity) key scratch and O(affected rows)
permutation metadata; wide components retain the existing movement costs.

Callers who use mutable access merely for reading can invalidate unnecessarily.
Raw-pointer users must explicitly mark; references cannot be retained across a
boundary. Structural-heavy workloads still classify every eligible entity.
Performance claims below cover synthetic host workloads, not application speedup.

## Evidence

- [Accepted alternative](0008-dirty-entity-spatial-classification.md), ECS-14.
- [Storage mutation integration](../../../src/larecs/host_storage.mojo),
  [execution/copy-back](../../../src/larecs/system.mojo),
  [candidate classification](../../../src/larecs/spatial.mojo).
- [Dirty, structural, failure/retry, copy, filter, and lock tests](../../../test/spatial_test.mojo),
  [actual GPU integration](../../../test/gpu_spatial_test.mojo), and unchanged
  [typed component lifetime coverage](../../../test/host_storage_lifecycle_test.mojo).
- [Paired complete-frame comparison](../../../benchmark/dirty_spatial.mojo) and
  [methods and measured limitations](../../src/guide/benchmarks.md#deferred-dirty-classification).
- [Public marking and boundary guide](../../src/guide/spatial_clustering.md).

The Apple M4/Mojo 1.0.0 paired complete-frame comparison found sparse dirty
updates taking 19.5–67.9% of explicit full-rebuild time, with fully dirty frames
at 99.1–104.6% after the all-ID-dirty contiguous-classification fallback. The
previous per-identity dense path took 131–141%, motivating that optimization.
The same-driver 44-case base-versus-worktree gate passed, but retained 15–19%
reversing-maintenance overhead and smaller access/mobile overhead. These are
accepted measured costs of invalidation checks and opt-in bookkeeping; the gate
thresholds are unchanged.
See the benchmark guide for hardware/compiler, setup exclusions, paired method,
absolute times, compilation cost, and application/memory limitations.
