---
id: "0021"
title: "Revision-tracked device copies that skip unchanged uploads"
status: accepted
status_notes: |
  Accepted; experimental. The resource half is implemented: revisions are
  drawn from a counter owned by the resource storage, which travels with its
  device copy records. Device resource tests compile for GPU targets but have
  not yet run on GPU hardware. Component columns are not implemented. Amends the unconditional-upload rule of
  decisions 0002 and 0018 for worlds that opt in; eager write-back is unchanged.
---

# Decision 0021: Revision-tracked device copies that skip unchanged uploads

## Context

Every `run[..., on_device=True]` call uploads all readable component columns
and required resources again. [Decision 0002](0002-gpu-system-execution.md)
reuses column allocations but transfers values on every call, and
[decision 0018](0018-portable-resource-adapters.md) reuses `ResourceDeviceCache`
capacity but calls `prepare_device` and rebuilds the descriptor on every
invocation. 0018 explicitly chose "no revision tracking".

Tree-D's `ComputeLeafLayersAboveSystem` runs one device kernel per light
direction, 13 runs per update, with the same filter: `read[Species, Position,
Height, CrownDimensions]`, `include[EffectiveLeafLayersAbove]`, and
`Resources().read[LeafDistribution, LightCompetitionParameters]`. The leaf grid
(16 samples × 4 `float32` per 1 m² cell, about 4.3 GB for a 4100 m plot) is
unchanged across the 13 runs but uploaded 13 times; the components are
unchanged too, apart from the column each run writes.

Relevant facts in the current code:

- `ResourceStorage.get` takes `ref self` and returns `UnsafeAnyOrigin`
  (0001, 0018). On a mutable world every `get`, including a pure read, is a
  mutable access, and the reference can outlive later Larecs calls.
- Mojo 1.0.0 does not reject use of a reference after its origin was mutated by
  a later `mut self` call, so references cannot be statically invalidated at a
  `run` call, even for component accessors whose origins are tracked.
- `DeviceComponentStorage` holds one flat buffer per component type, shared by
  all systems. Each call packs its filter's matching stores at increasing
  offsets and recomputes them for the download within the same call; nothing
  records between calls which store occupies which offset.
- Live store indices in `HostStorage._archetypes` never move, but emptied spatial
  partition stores become tombstones and their indices are reused by new
  clusters (decisions 0006, 0014; `spatial.mojo`).

## Decision

### Scope

One mechanism covers ordinary resources, adapted resources, and component
columns. Resources are implemented first. Writable device-resident resources,
lazy download, and kernels over index ranges are deferred to a later decision;
this design must not preclude them.

### Opt-in per world

`world.reuse_device_copies(enabled: Bool)` is a runtime, experimental switch,
off by default. With it off, behavior and transfers are byte-identical to today.
Disabling it clears every device copy record. Revisions are maintained
regardless of the switch, so enabling it needs no migration.

### Coherence: host authoritative, eager write-back

The host stays authoritative. `run` remains synchronous and still downloads
every written column and `read_write` resource, publishing only after
successful synchronization. After a successful run, host and device hold equal
bytes for everything the kernel touched, so the next run may skip uploading the
columns it just wrote as well as those it only read. Only uploads are skipped.

### Revisions

Larecs keeps a **revision** per resource and per (component type, physical
store). Revisions are drawn from one increasing counter per world, so a value
is never reused, including when a reclaimed store index is reused by a new
store. A device copy records the revision it was transferred at; it is
**stale** when that differs from the current revision. Skipping is never based
on content hashing or only on user marking.

The following conservatively advance revisions:

| Item | Advancing operations |
| --- | --- |
| Resource | `add`, `set` and insert-on-`set`, whole-instance replacement, any `get` through mutable storage, and host or threaded runs declaring `write` or `read_write`. `remove` drops the device copy. Any later resource write access for host runs, such as the partitioned write proposed in decision 0020, advances it too. |
| Component column of a store | Host, threaded, and selection runs writing `T`, for the stores they matched; mutable entity access (`get`, mutable query items) for the accessed types of that store. |
| All columns of a store | Structural changes, spatial reordering, and partition moves that change row positions; creation of a store, including reuse of a reclaimed index. |

New non-advancing accessors mirror the access mode names:
`world.resources.read[T]()` returns an immutable reference, and
`world.read[T](entity)` mirrors `get` for components. Query items for
`Filter().read[T]` do not advance revisions. World copies start without device
copy records, like resource caches.

### Device runs and failures

A successful device run advances the revision of each item it wrote and stamps
the device copy with that same revision. If an invocation fails after work was
queued, every device copy it uploaded to or wrote is marked unknown, so the
next run re-uploads it. This applies whether or not the drain succeeds; the
`_execution_unusable` rules of 0018 are unchanged.

### Component segments

Each device column records the ordered segments of its last transfer:
(store, row start, row count, revision). Offsets follow from order and counts.
Selection runs (0001) record their exact ranges the same way. An upload is
skipped per segment only if the store, range, offset, and revision all match;
any other segment is uploaded. Write-only columns are not uploaded, as today,
and are recorded after their download.

### Resources and adapters

When a resource's revision matches its device copy, Larecs skips the whole
`prepare_device` call and reuses the descriptor already in cache slot `-1`.
`validate(source)` still runs on every invocation, and leases are taken as in
0018. The `ResourceAdapter` trait is unchanged: no version method on `Source`.
Whenever `cache.upload` runs, it still snapshots before enqueueing. Ordinary
pointer-free resources follow the same revision rule. Captures are per-call
values and are always uploaded.

### Escaped references and raw pointers

Mutations through references obtained before a later Larecs call, or through
raw pointers (`unsafe_ptr`, `get_component_ptr`), are not detected. In a world
that opted in, callers must re-obtain references after a run or invalidate
explicitly:

- `world.resources.invalidate_device[T]()` marks one resource's device copy stale.
- `world.invalidate_device_copies()` marks every device copy stale.

Per-component invalidation may be added when a user needs it. Public guides must
document this rule prominently next to the opt-in switch and the resource
accessors.

## Rationale

- **Counters over hashing:** hashing a 4.3 GB grid on the host costs roughly as
  much as uploading it. Explicit marking alone turns every forgotten mark into a
  silent stale result. Conservative counters are correct for all Larecs entry
  points and need marking only for escaped aliases.
- **Opt-in:** an automatic default would make an existing legal pattern, mutating
  through an escaped reference between runs, a stale-copy bug. Opting in makes
  that contract change explicit while the feature is experimental.
- **Guard handles (deferred):** `get` could return a guard whose destructor
  releases an outstanding-borrow count; under ASAP destruction, a guard still
  used after a `run` is alive during it, so `run` could treat that item as
  changed. This is the path to an automatic default, but it changes the return
  types of resource and component accessors, inner-reference lifetime behavior
  is unverified, and raw pointers still escape. A probe is planned.
- **Eager write-back:** lazy download would require intercepting every host
  path (queries, `get`, raw pointers, host and threaded kernels, spatial moves,
  world copies). Eager download keeps synchronous completion and publication
  semantics and still lets written columns be reused on the next run.
- **Segments over per-store device allocations:** stable per-store device
  buffers would need a store table in the kernel and change grid-stride
  iteration (0003). Segment records keep the packed layout.
- **Granularity:** physical stores are the unit of contiguous rows and of
  spatial moves; without partitioning, a logical archetype has one store.

## Consequences

- Tree-D's repeated runs upload the grid, read components, and
  `EffectiveLeafLayersAbove` once instead of 13 times; the 13 downloads of the
  written column remain.
- Any `get` through a mutable world advances that resource's revision, so code
  that wants skipping uses the `read` accessors for reads between runs.
- Systems using different filters on the same component type pack stores at
  different offsets and evict each other's segments. This is a known limitation.
- Device column records, cache descriptors, and revisions add small per-world
  state. Disabling the switch or copying the world discards device copy records.
- Users of opted-in worlds who mutate through escaped references or raw pointers
  without invalidating get stale device results; there is no runtime detection.

## Evidence

Planned validation, none implemented yet:

- An internal per-invocation transfer counter (bytes and segments uploaded) for
  tests to assert skips.
- One stale-copy test per advancing operation listed above: mutate between two
  device runs and assert that the second result reflects the change.
- Escape-hatch tests: a raw-pointer mutation is stale without invalidation and
  fresh with it.
- Store identity tests: live store indices are unchanged across structural
  changes, spatial maintenance, and partition moves; a reused reclaimed index
  receives a fresh revision so an old segment never matches.
- Failure after upload re-uploads on the next run; alternating filters evict
  each other; world copies start without records; disabled worlds transfer
  exactly as today.
- [Adapter benchmark](../../../benchmark/resource_adapter_benchmark.mojo)
  extended with 13 unchanged repeated runs, reporting bytes and time, and a
  before/after run of Tree-D's `light_benchmark`.
- [Mojo reference probe](../research/reference-invalidation-probe.mojo)
  shows that Mojo 1.0.0 accepts a write through a reference after a
  `mut self` call on its origin.
