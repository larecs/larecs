+++
type = "docs"
title = "Spatial APIs and synchronization"
weight = 5
+++

Spatial classification groups entities by application-defined keys. It changes physical placement without changing an entity's component composition or identity; [row indices are not entity IDs](../compatibility#row-indices-are-not-entity-ids).

| API | Contract |
| --- | --- |
| {{< api SpatialClassifier >}} | Define the classification key for the registered component types. |
| {{< api grid_cell >}} | Convert position coordinates to a grid cell using the supplied cell size. |
| {{< api morton_key_3d >}} | Encode a three-dimensional integer cell as a Morton key within the documented coordinate limits. |
| {{< api AtomicValue >}}, {{< api AtomicView >}} | Own an atomic value or borrow an atomic view; operations expose their memory ordering parameters. |
| {{< api CompareExchangeResult >}} | Reports compare-exchange success and the observed value. |
| {{< api Synchronized >}}, {{< api SyncView >}} | Own guarded state or borrow its view. Use nonblocking `try_read` or `try_write` and check acquisition. |
| {{< api TryAccess >}} | Test `is_acquired()` before consuming the result with `take()`. Keep access within the acquired guard's lifetime. |

The generated declarations define supported value types, origins, mutation rights and memory orderings. See [maintaining particle locality](../../guide/spatial_locality/maintain) and [coordinating shared writes](../../guide/execution/shared_writes) for complete examples. Synchronization does not grant undeclared component/resource access or permit structural mutation during kernel execution.

## Classifier registration

- `world.register_spatial_classifier[filter](classifier, partitioned=...)` stores one copyable classifier per world; a second registration raises, as does registration on a locked world. Registration requests a full rebuild but moves no rows.
- Only archetypes matching the registration filter participate. All filter types must belong to the world. The classifier's `Accessor` must match the filter exactly; writable `include` or `write` inputs are rejected. Ordinary include, exclude, and exclusive rules apply.
- `classify` must be deterministic, must not mutate the world, and must not retain accessors or references.
- {{< api grid_cell >}} floors `coordinate / width`. Coordinates and width must be finite, the width positive, and the resulting cell within `[-1048576, 1048575]`.
- {{< api morton_key_3d >}} biases each signed 21-bit axis and interleaves the bits into a collision-free 63-bit key. Invalid inputs raise; they never clamp or wrap.

## Spatial maintenance

{{< api World.maintain_spatial >}} is the only operation that moves rows for classification. Kernel and system completion never run it.

| Topic | Contract |
| --- | --- |
| Preconditions | Raises on a locked world; see [empty queries and selections hold structural locks](../compatibility#empty-queries-and-selections-hold-structural-locks). Component references do not survive maintenance, even a clean no-op; reacquire them by entity handle. |
| Row ordering (`partitioned=False`) | Sorts eligible rows by ascending key within their component-defined physical stores. Equal keys become contiguous; tie order is unspecified. Unchanged rows can move to restore contiguous groups. |
| Partitions (`partitioned=True`) | One growable dense store per logical archetype and cluster key. Capacity starts at one row and doubles; there is no fixed row limit or chunk-size setting. Store traversal is not globally key-sorted, and clusters need not have adjacent allocations. |
| Staging | In partition mode, creation and component transitions place rows in a staging store until maintenance. Queries and kernels visit staged rows. Same-composition replacement stays in its current store until refreshed. Maintenance releases empty cluster and staging allocations; nonempty stores keep their capacity. Destination growth can relocate existing rows. |
| Dirty tracking | Declared writable kernel ranges (host, threaded, and device copy-back), setters, and mutable `storage.get` mark affected classifier inputs, conservatively, even when only read. `read` and read-only queries do not. Writes to unrelated components never mark. |
| Untracked writes | Raw pointers and low-level storage writes bypass tracking. Call `world.storage.mark_spatial_dirty(entity)` per affected live entity, or {{< api World.invalidate_spatial >}} for a full rebuild; external policy changes also need full invalidation. Both calls move no rows. |
| Work per pass | A clean pass touches no rows. Each dirty eligible entity is classified once per pass. Registration, structural changes, and full invalidation request a full rebuild; if every allocated entity is dirty, maintenance classifies contiguously. Active passes still copy identity-capacity keys and rebuild a temporary cluster directory. |
| Failure | All fallible classification and reorder planning precedes row movement. Classifier errors preserve committed keys, row order, and dirty state for a retry. Fatal allocation or lifecycle failures offer no rollback. |

## Cluster selection

{{< api SystemContext.select_cluster >}} returns an {{< api EntitySelection >}} of the rows whose maintained key equals the requested key, across logical archetypes and intersected with the given filter. It raises without partition mode, without clean maintenance, or on a locked world. Membership stays fixed until release, even after member positions change. Even an empty selection holds a structural lock. Cluster selection scans store metadata; it is exact key equality, not a radius query, and Morton key adjacency does not imply spatial adjacency.

## Synchronization primitives

These standalone primitives operate on storage you own. Larecs does not bind them to kernels: an `AtomicView` or `SyncView`, or an aggregate containing one, is rejected as an ordinary resource or capture. A custom mutable adapter may implement an atomic protocol over its own target-local buffers.

| Topic | Contract |
| --- | --- |
| Atomic scalars | `UInt32` and `Int32` only. Add and subtract wrap at that width and return the previous value. Strong `compare_exchange` returns success and the observed value. Read views permit loads only. |
| Ordering | Operations default to relaxed ordering, passed at compile time. Loads also accept acquire, stores release, and read-modify-write operations acquire, release, or acquire-release. Relaxed counters do not publish adjacent ordinary data. Guards use acquire and release internally. |
| Guards | Multiple read guards may coexist; a writer excludes all guards. `try_read` and `try_write` make at most one compare-exchange attempt. A false {{< api TryAccess.is_acquired is_acquired >}} means Busy, including a changed state or reader saturation; there is no wait, fairness, lock upgrade, or retry. |
| Guard lifetime | Owners and guards are noncopyable; copied views share one protection state. References from `guard.value()` stay within the guard's lifetime. Scope exit, including error unwinding, or `guard^.release()` releases access. Errors do not roll back payload writes. |
| CPU, NVIDIA, AMD | The full scalar and guard operation set, with CPU-wide or whole-device scope. |
| Apple device | Relaxed or acquire loads, relaxed or release stores, and relaxed add and subtract. Strong compare-exchange, ordered add and subtract, and guards fail to compile. |
| Device memory | Payload and state must be aligned, initialized, device-accessible, and alive until completion. Unsafe view constructors do not allocate, transfer, or validate that memory. One canonical unlocked state must protect every overlapping guarded payload. Host and device allocations are separate domains; the primitives do not permit concurrent CPU and GPU access to one allocation. |
