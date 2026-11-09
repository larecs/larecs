+++
type = "docs"
title = "Spatial maintenance"
weight = 6
+++

We store an owned {{< api SpatialClassifier >}} and typed maintenance callback
on the world. Its explicit read-only filter selects eligible compositions and
classifier inputs. The current world holds one classifier. A `UInt64`
**cluster key** groups locality; neither key adjacency nor placement guarantees
exact neighbors.

## Invalidations before movement

The storage owns a queue of full ID/generation identities, sparse membership
bits indexed by entity ID, committed keys, and a full-rebuild flag. Repeated
input writes enqueue an identity once; classification reads its final values
at the explicit boundary. Mutable input exposure and declared kernel writes
mark conservatively, including device copy-back. Registration, structural
changes, and explicit invalidation request a full rebuild.

The boundary separates callbacks from physical mutation.

![Mutable classifier input exposure queues unique entity identities; explicit unlocked maintenance computes pending keys and plans before moving rows and committing keys. Classifier failure retains prior rows and dirty state.](/images/spatial-maintenance.svg)

*All classifier callbacks finish before any row moves.*

`maintain_spatial` first rejects a locked world. A clean call returns without
row work. Otherwise it builds pending keys from the cache or a full scan,
validates liveness/eligibility for dirty identities, and prepares permutations
or partition placement. Classifier errors preserve prior order, committed keys,
and pending invalidations. Once planning succeeds, typed movement repairs
locations and commits keys, then clears dirty state. Allocation failure is
fatal as in ordinary storage; this is not a general rollback transaction.

Mutable references cannot span maintenance. Low-level raw writes require
explicit marking or invalidation because they bypass automatic tracking.
System/kernel completion marks work but never runs spatial maintenance itself.

## Two physical layouts, one logical composition

The adapted ordering/grouping figure shows the two implemented placement modes.

![Default ordering makes equal keys contiguous in one physical store; partition mode moves newly staged D to the growable k0 store while k1 remains separate.](/images/spatial-placement.svg)

*Partition stores share a component mask and logical transition node.*

Default maintenance sorts affected stores by ascending key and applies typed
permutations to IDs and every active column. Equal-key rows become contiguous;
applications cannot depend on tie order. Clean rows can move when regrouping
requires it.

Opt-in partition mode retains a canonical staging store for creation and
structural transitions. Maintenance moves rows into one growable store per
logical-archetype/key pair, swap-removes source rows, and repairs locations.
Destination growth can relocate existing values. Empty cluster stores release
row allocations and recycle directory slots with fresh incarnations. Nonempty
stores retain spare capacity; there is no current fixed 256-row cluster cap.

Ordinary queries and kernels include staging and cluster stores through the
same mask/range traversal. Exact cluster selection requires clean maintenance
and scans metadata; it does not build a neighbor index. Sparse maintenance
still copies identity-capacity keys and scans store metadata, so classifying
only dirty identities does not make total maintenance O(dirty identities).

The thesis's memory blocks and historical bounded partitions explain the
design lineage. Current growth and reclamation follow
{{< repo "docs/design/decisions/0014-growable-cluster-stores.md" "decision 0014" >}},
which supersedes 0013. The rejected special `Cluster` component in 0007 is not
part of placement. [Partition reports](../../development/reports/partitions)
retain measurements with their layout and revision labels.

Implementation: {{< source "spatial.mojo" >}},
{{< source "host_storage.mojo" >}}, {{< source "world.mojo" >}}.
Evidence: {{< repo "test/spatial_test.mojo" >}},
{{< repo "test/partitioned_spatial_test.mojo" >}},
{{< repo "test/gpu_spatial_test.mojo" >}}.
For the application boundary, use [Maintain particle locality](../../../guide/spatial_locality/maintain).
