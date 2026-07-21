+++
type = "docs"
title = "Pluggable multi-storage ECS"
weight = 10
+++

Status: proposed

## Summary

Larecs should separate logical ECS state from physical component storage.
`World` should continue to own entity identity, archetype composition, and
structural changes, but delegate allocation, column operations, transfers, and
execution access to a `StorageCoordinator`. The coordinator manages one or more
storage backends at the same time.

A component column may have a primary copy and zero or more replicas in
different storages. All copies use the same logical archetype row coordinate.
Queries declare what they read and write and where they execute. The
coordinator then selects existing data, transfers it, or rejects an unsupported
request. A versioned, single-writer coherence protocol makes writes in one
storage visible to later work in another storage.

The important boundary is therefore not a virtual `get_component(index)`
method. Such a method would preserve the current CPU assumptions and add
dispatch to the hottest loop. The boundary must operate on whole columns and
ranges, while query iteration or GPU kernels access a backend-specific view
without per-entity dispatch.

## Motivation

The current implementation combines logical ECS behavior and host allocation:

- `World` directly owns the archetype list, entity locations, graph, and locks
  in `src/larecs/world.mojo`.
- `Archetype` owns a concrete `_ComponentStorage` and a parallel entity list in
  `src/larecs/archetype.mojo`.
- `_ComponentStorage` allocates typed host pointers and directly implements
  reserve, copy, move, destruction, and swap-remove.
- `Query` stores a pointer to `List[Archetype]`, scans it, and yields accessors
  containing direct references into host columns in `src/larecs/query.mojo`.
- Adding or removing a component copies values directly between two concrete
  archetypes. Entity locations assume one dense row space.
- Systems receive only `mut World`; they do not declare read/write sets,
  execution placement, or asynchronous dependencies.

This works well for one synchronous, host-addressable storage, but a GPU
backend cannot implement the same contract:

- Device-only memory cannot be returned as a normal host `ref`.
- Transfers and kernels are asynchronous and have fences that can outlive a
  lexical function call.
- A mutable host reference gives the ECS no opportunity to mark a replica
  stale.
- Device allocation, copy, and destruction are not equivalent to `alloc`,
  `uninit_copy_n`, and `destroy_n`.
- Two storages require an explicit authority and synchronization model; raw
  pointers alone cannot provide coherence.

## Goals

- Allow a world to contain multiple storage instances concurrently, including
  host storage, one or more GPU storages, pinned transfer storage, and custom
  storages.
- Allow systems using different storages to consume each other's results.
- Preserve archetype-based filtering and structure independently of physical
  placement.
- Keep the CPU query hot loop statically dispatched and as close as possible to
  its current performance.
- Support asynchronous transfers and device execution without hidden global
  synchronization.
- Keep structural changes atomic from the perspective of queries.
- Permit placement and replication policy to vary by component, archetype, and
  workload.
- Make unsupported component/backend combinations fail during planning, before
  partial mutation.

## Non-goals

- Making arbitrary heap-owning Mojo values usable in GPU memory.
- Returning a host `ref` to device-only data.
- Transparently running an existing scalar CPU system as a GPU kernel.
- Maintaining coherent mutable references in two storages simultaneously.
- Requiring every backend to share an allocator, memory layout, or command API.
- Implementing distributed networking in the first version. The transfer and
  fence model should not preclude it, but network failure semantics are a
  separate design.

## Terminology

| Term | Meaning |
| --- | --- |
| Storage backend | A backend type implementing allocation, column operations, transfers, and access preparation for one memory/execution domain. |
| Storage instance | One configured backend value, such as host storage, GPU 0, or GPU 1. Instances have stable `StorageId`s. |
| Logical archetype | A component mask and its entity membership, independent of where component bytes reside. |
| Fragment | Physical columns for a logical archetype and row range in one storage. |
| Column key | `(ArchetypeId, ComponentId, row range)`, identifying logical values independently of storage. |
| Replica | A physical copy of a column key in a storage. |
| Lease | A scoped grant for read or exclusive write access to prepared columns. |
| Fence | Completion token for a transfer, kernel, or other asynchronous operation. |

## Proposed architecture

The design has four layers:

```text
Systems and public World API
            |
            v
Logical ECS control plane
EntityRegistry + ArchetypeIndex + structural transactions
            |
            v
StorageCoordinator
placement + replicas + versions + transfers + leases
            |
            v
StorageSet[HostStorage, GPUStorage, ...]
backend fragments, buffers, queues, and fences
```

The design maintains these invariants:

1. The logical control plane is the only authority for entity identity,
   archetype membership, and row assignment.
2. Every fragment for one logical archetype uses the same row-to-entity
   mapping.
3. Every column key has exactly one latest version, although several replicas
   may contain it.
4. Component bytes are accessed only through a lease prepared for one storage
   domain.
5. A topology change is published atomically across the entity registry and
   every affected fragment.
6. A fragment allocation remains alive until all leases and fences referring to
   it are complete.

### Logical ECS control plane

The control plane is always host-resident in the initial design. It owns:

- entity allocation and generations;
- `Entity -> (ArchetypeId, row)` locations;
- component masks and the archetype graph;
- the canonical entity sequence for every archetype;
- topology epochs and structural locks;
- storage placement policy, but not component buffers.

`Archetype` becomes a logical record rather than a component container. Its
entity sequence and row count define the canonical row coordinate shared by all
physical fragments. A backend may mirror entity IDs when a device kernel needs
them, but that mirror follows the same coherence rules as a component column.

Keeping entity identity and topology out of a backend is essential. Otherwise,
two storages would each have a competing answer for where an entity lives, and
cross-storage queries would require an entity-ID join. Shared rows make a
component at row `r` in host storage correspond to the same entity as a
component at row `r` in GPU storage.

The first implementation should retain one dense range per archetype. The
model can later split an archetype into fixed-size row chunks for sharding or
incremental transfers; chunk boundaries become part of the column key and do
not change entity semantics.

### Storage coordinator

`StorageCoordinator[*ComponentTypes, StorageSet]` is the only control-plane
type allowed to call backend storage operations. It owns:

- the configured storage instances and their capabilities;
- the physical fragment directory;
- placement rules;
- the authoritative version and replicas of each column key;
- outstanding fences;
- active read and write leases;
- transfer route selection and reusable staging buffers.

`World`, logical archetypes, and queries refer to stable IDs and column keys,
not backend pointers. Backend pointers are exposed only inside a prepared,
backend-specific lease.

### Storage backend contract

The contract should be coarse-grained. The following is illustrative Mojo-like
pseudocode, not a final source API:

```mojo
trait StorageBackend(Movable):
    comptime address_space: StorageAddressSpace

    def supports_component[T: ComponentType]() -> Bool: ...
    def create_fragment(mut self, descriptor: FragmentDescriptor) raises -> FragmentHandle: ...
    def reserve(mut self, fragment: FragmentHandle, capacity: Int) raises -> Fence: ...
    def append_uninitialized(mut self, fragment: FragmentHandle, count: Int) raises -> RowRange: ...
    def copy_local(mut self, request: LocalCopyRequest) raises -> Fence: ...
    def swap_remove(mut self, fragment: FragmentHandle, row: Int) raises -> Fence: ...
    def clear(mut self, fragment: FragmentHandle) raises -> Fence: ...
    def destroy_fragment(mut self, fragment: FragmentHandle) raises -> Fence: ...
```

Typed column views are a separate, statically dispatched capability. A host
backend can prepare `Span[T]`-like views. A GPU backend can prepare device
buffers or `TileTensor`-compatible views for a kernel launch. The generic query
loop does not call the methods above per entity.

Backends also advertise capabilities such as:

- host addressability;
- device launch support;
- supported component layouts and alignment;
- asynchronous operation support;
- peer-to-peer transfer with another storage instance;
- host staging requirements;
- maximum allocation and preferred transfer granularity.

The storage set should be a compile-time pack, with runtime `StorageId`s used to
select instances. Dispatch can be implemented as a `comptime for` over the pack
or a tagged variant. This provides heterogeneous storage without a virtual call
inside component access. A Mojo feasibility spike should settle the exact
parameter ordering and existential/variant representation before the public
type signature changes.

Cross-backend copies use transfer adapters selected by the coordinator. A
`TransferAdapter[SourceBackend, DestinationBackend]` receives opaque exported
buffer descriptors from each side and returns a destination fence. This keeps
backend handles private while allowing specialized peer-to-peer routes. The
coordinator supplies a host-staged adapter when no direct adapter exists.

### Host storage

The first backend is `HostStorage`. It owns the typed column pointers currently
inside `_ComponentStorage` and contains the existing lifecycle operations.
Extracting it should not initially change layout, growth, or query iteration.
This backend is both the compatibility implementation and the reference
backend for correctness tests.

### GPU storage

`GPUStorage` owns a `DeviceContext`, device buffers, a command queue, and fence
state. Its fragments store device-compatible columns in structure-of-arrays
form. It implements copies with enqueued buffer operations and exposes prepared
device views to bound Mojo kernels.

GPU buffers are not mapped merely to implement `World.get`. A host access
request instead asks the coordinator for a host replica. The coordinator waits
only for dependencies of that column, transfers the current version if needed,
and returns a host lease.

## Component eligibility and layout

`ComponentType = Copyable & ImplicitlyDeletable` is sufficient for the current
host backend but does not prove device compatibility. Eligibility belongs to
the backend or a component storage policy, not to the base ECS component trait.

The GPU backend should require a stricter compile-time predicate covering at
least:

- fixed size and alignment known to both host and device code;
- device-passable field types;
- no host pointer ownership or host-only destructor;
- a defined transfer representation;
- compatible copy and initialization behavior.

Most components should use the same representation in host and device storage.
The design may later support a `StorageCodec[T, Backend]` for explicitly
different representations, but implicit serialization should not be in the
first GPU backend. A codec complicates reference semantics, versions, and
partial writes.

Placement policy is separate from eligibility. Examples include:

- `HostOnly[Name]`;
- `PrimaryOn[Position, gpu0]`;
- `Replicate[Transform, host, gpu0]`;
- a runtime policy choosing a GPU only above an archetype-size threshold.

## Coherence model

The coordinator maintains a monotonically increasing version for every column
key. Each replica records the version it contains and a fence that will make
that version available.

The protocol is single-writer, multiple-reader:

1. A read lease requests version `v`, the latest committed version.
2. If the selected storage already has `v`, it waits on or depends on that
   replica's fence.
3. Otherwise the coordinator schedules a transfer from a replica that has `v`.
4. Multiple read leases may coexist after their dependencies are established.
5. A write lease is exclusive for that column range and depends on prior
   readers and writers.
6. Committing a write lease creates version `v + 1` in its storage. Other
   replicas remain allocated but become stale.
7. A later reader in another storage transfers `v + 1`; stale replicas are
   never read.

An operation that reads and writes the same column acquires one read-write
lease rather than separate leases. Version publication occurs when the
operation is enqueued, together with its completion fence. Consumers can depend
on the fence without synchronizing the entire device.

Direct mutable host references cannot report whether they were actually
changed. Therefore any legacy mutable accessor must conservatively acquire a
write lease and publish a new version when released. New APIs should distinguish
`Read[T]` and `Write[T]` so read-only CPU queries do not invalidate device
replicas.

Coherence is per column range, not per entity. Per-entity dirty tracking would
add overhead to the CPU hot path and usually produce inefficient GPU transfers.

## Transfers between storages

Storages interact through the coordinator, never by reaching into each other's
private handles. For each transfer it selects one of:

1. Shared or unified memory, requiring only a dependency fence.
2. Direct peer-to-peer copy when both backends advertise a compatible route.
3. Copy through a coordinator-owned pinned host staging buffer.
4. A backend-provided conversion path when an explicit storage codec exists.

The source replica remains authoritative until the copy completes. Failed
transfers do not publish the destination version. Transfer requests should be
coalesced across adjacent columns or row ranges where the backend benefits,
without changing the logical coherence unit.

This mechanism supports multiple simultaneous storages rather than a global
"CPU mode" or "GPU mode". GPU 0 can produce `Position`, GPU 1 can consume it
after a peer or staged transfer, and a host system can independently consume
`Health`. The directory records each dependency explicitly.

## Storage reconfiguration

Swapping a storage implementation at runtime is a relocation transaction, not
an exchange of backend pointers:

1. Add and initialize the destination storage instance.
2. Stop assigning new primary placements to the source instance.
3. Acquire leases for the columns that must survive the change.
4. Copy each latest version to the destination using normal transfer routes.
5. Atomically update placement policy and the replica directory.
6. Wait for remaining source fences, then destroy its fragments and remove the
   instance.

The source and destination coexist while relocation is in progress, so systems
using unrelated columns continue to run. A static world configuration may omit
runtime removal while still using the same protocol during construction. A
backend can also be replaced at compile time by changing `StorageSet`, provided
the configured placement policy remains satisfiable.

## Queries and access

Query filtering remains a logical operation over archetype masks. Data access
becomes a second planning step.

A query descriptor contains:

- included and excluded component masks;
- a read, write, or read-write mode for each accessed component;
- preferred or required execution storage;
- an optional row partition;
- synchronization policy, such as eager wait or returned fence.

Conceptually:

```mojo
var query = world.query[
    Read[Position], Read[Velocity], Write[Acceleration]
]().on(gpu0)
```

This is syntax direction only. The final API must account for Mojo's variadic
parameter and origin constraints.

### Host queries

A host query prepares all requested columns in a host-addressable storage,
acquires leases, and then yields an accessor backed by direct typed pointers.
The inner loop remains equivalent to current archetype iteration. The iterator
owns the leases in addition to the topology lock, and releasing it commits
writes.

`World.get[T]` is defined as a one-row host access. It may transfer and wait, so
its documentation must no longer imply a uniformly cheap operation. An
explicit `get_on[T](storage_id, entity)` or batch access API should be preferred
in performance-sensitive code.

For compatibility, the existing `query[T, ...]` and mutable `get[T]` can target
the default host storage and conservatively declare writes. They cannot operate
when no host-compatible replica can be created.

### Device queries

A device query does not implement the host iterator protocol and does not yield
`EntityAccessor`. It prepares device column views and dispatches a kernel over
each matching archetype range. A possible shape is:

```mojo
world.query[
    Read[Position], Write[Velocity]
]().on(gpu0).dispatch[update_velocity](dt)
```

The dispatch returns a fence or records it in a command graph. Kernel arguments
are bound backend views plus row count and any user arguments. The coordinator
publishes written versions with the kernel fence.

Keeping host iteration and device dispatch as separate terminal operations
prevents a misleading common abstraction. They share query selection, access
declarations, placement, and coherence, but not element access mechanics.

### Cross-storage queries

A single execution step runs in one storage domain. If its requested columns
currently reside in several storages, the planner materializes current replicas
in the execution storage before the step starts. Because all fragments share
logical rows, this is a set of column transfers rather than an entity join.

A system that intentionally pipelines work across devices expresses multiple
steps with fences between them. It does not receive one accessor containing
pointers from incompatible address spaces.

## Structural changes

Adding or removing entities or components changes shared row topology and must
be coordinated across every physical fragment. The first implementation should
make structural operations host-driven and synchronous at the transaction
boundary, even when component copies are performed by a GPU.

A structural transaction is:

1. Acquire an exclusive topology lease for the affected archetypes.
2. Wait for outstanding operations touching their rows.
3. Resolve or create the destination logical archetype.
4. Build a plan for every retained, added, and removed column.
5. Validate backend support and reserve all destination fragments. No logical
   metadata changes before all reservations succeed.
6. Copy retained columns from their current authoritative replicas, initialize
   added columns, and wait for these operations.
7. Publish the destination row and update the entity location.
8. Perform the same swap-remove row operation in every source fragment.
9. Update the swapped entity's location and increment the topology epoch.
10. Release the topology lease.

Batch operations use ranges but follow the same phases. Backends must never
choose their own row during append or swap-remove; the transaction supplies the
logical row. Debug builds should assert equal row count and capacity coverage
for all fragments of an archetype.

Initially synchronizing structural changes is deliberately conservative.
Asynchronous topology mutation can be added later by versioning entity
locations and query snapshots, but it should not complicate the first storage
abstraction.

## Scheduler integration

Storage interaction is most effective when the scheduler knows access before a
system runs. Systems should eventually expose an access descriptor containing:

- component read/write sets;
- resource read/write sets;
- preferred execution storage;
- whether the system performs structural mutation;
- whether it returns asynchronous work.

The scheduler can then build dependencies from data hazards and insert transfer
steps. Two systems may overlap when they access disjoint columns or only read
the same version. A host consumer waits only on the GPU producer columns it
uses, rather than synchronizing all GPU work.

Manual code remains valid: preparing a query immediately asks the coordinator
to satisfy its dependencies. Declared systems enable ahead-of-time planning
and transfer coalescing but are not required for correctness.

## Locking, origins, and lifetime

The current query lock prevents structural mutation while accessors carry
origins tied to the archetype list. Multi-storage access requires two distinct
mechanisms:

- a topology lease prevents archetype rows or fragment handles from changing;
- data leases and fences order reads and writes to component bytes.

A prepared host view carries an origin tied to its lease, not to a backend's
entire allocator. Destroying the iterator releases the view and commits any
write. A backend cannot reserve, relocate, or destroy a leased fragment.

Device views cannot rely on Mojo host reference origins after dispatch. Their
validity is represented by backend ownership plus the completion fence. The
coordinator retains fragment allocations until all fences using them complete.

This removes the need for query code to know that archetypes happen to be
elements of a `List`, although an internal host iterator may still require an
origin-safe container design.

## Errors and failure atomicity

Planning can fail because a component is unsupported, a required storage is
unavailable, no transfer route exists, allocation fails, or leases conflict.
These failures must happen before user work starts.

Structural transactions require stronger guarantees:

- reservation and transfer failure leaves logical entity locations unchanged;
- unpublished destination rows may be discarded after their fences complete;
- a failed asynchronous write never publishes a new readable version;
- device loss marks affected replicas unavailable; another current replica may
  be promoted, otherwise accesses to the column fail explicitly.

Backends return typed Larecs storage errors enriched with storage, archetype,
component, and operation IDs. They should not leak vendor-specific exceptions
through the public query API without context.

## Copy and destruction semantics

The current `World` and `Archetype` are `Copyable`, with deep copies of host
columns. Device contexts, queues, leases, and in-flight work do not have useful
implicit copy semantics.

A multi-storage world should not conform to `Copyable` merely to preserve that
behavior. It should offer an explicit operation such as `clone_to(config)` that
waits for a coherent snapshot and copies authoritative values according to the
destination placement policy. Moving a world transfers backend ownership.
Destruction waits for or safely retires in-flight operations before releasing
buffers.

## Example interaction

Consider host storage and `gpu0` with `Position`, `Velocity`, and `Name`:

1. Entities are created on the host. `Name` is host-only; numeric columns have
   host version 1.
2. A GPU movement system requests read-write `Position` and read `Velocity`.
   The coordinator copies version 1 of both numeric columns to `gpu0`.
3. The kernel is enqueued. `gpu0` becomes the producer of `Position` version 2,
   pending on fence `F1`. Host `Position` version 1 remains allocated but stale.
4. A host logging system reads only `Name`; it runs immediately because it has
   no dependency on `F1`.
5. A host rendering system reads `Position`. The coordinator schedules a copy
   of version 2 after `F1`, waits for that copy at host query entry, and yields a
   direct host view.
6. A second GPU system reads `Position` on `gpu0`; it depends directly on `F1`
   and performs no transfer or host synchronization.

This is the required multi-storage behavior: storage instances coexist,
operations remain local when possible, and interaction is an explicit data
dependency rather than a global storage swap.

## Migration plan

### Phase 1: Extract host storage

- Move `_ComponentStorage` allocation and column lifecycle behavior into
  `HostStorage`.
- Introduce stable `ArchetypeId`, `FragmentHandle`, and logical archetype
  metadata.
- Route structural operations through a one-backend coordinator.
- Preserve the current public API, layout, tests, and benchmark performance.

Exit criterion: one host backend passes all existing tests with no material
regression in access, query, and migration benchmarks.

### Phase 2: Access descriptors and leases

- Add read/write query descriptors.
- Split host iteration from a generic prepared-query plan.
- Make legacy mutable queries conservative write leases.
- Replace the single world lock role with topology and data leases.

Exit criterion: read-only queries can overlap, writes invalidate replicas in a
test coordinator, and direct host access remains pointer-based inside a lease.

### Phase 3: Multiple host-backed storages

- Add `StorageSet` dispatch, placement policy, column directory, versions,
  fences, and transfers.
- Use two separately allocated host backends to test all multi-storage behavior
  without requiring GPU hardware.
- Test stale-replica prevention, transfer failure, and cross-storage systems.

Exit criterion: producers and consumers can alternate between two storage
instances with deterministic results and no unnecessary copies.

### Phase 4: GPU backend

- Implement device fragments, enqueued transfers, and fences with
  `DeviceContext` and device buffers.
- Add device component eligibility checks.
- Add device query dispatch and backend views suitable for `TileTensor`.
- Start with synchronous world structural mutation and asynchronous kernels.

Exit criterion: a GPU system can consume host-created data, update it, feed a
second GPU system without a host round trip, and later feed a host query.

### Phase 5: Scheduler planning and optimization

- Add system access declarations and command graph construction.
- Coalesce transfers and overlap independent host, transfer, and device work.
- Evaluate chunked archetypes and multi-GPU row partitioning using benchmark
  evidence.

## Test plan

The abstraction needs backend contract tests shared by every backend:

- fragment creation, reserve, clear, destruction, and zero-size behavior;
- typed alignment and component eligibility;
- append and swap-remove preserving canonical rows;
- range copy within one backend and across backend pairs;
- fence ordering and allocation lifetime;
- read/read, read/write, and write/write lease behavior;
- version publication and stale-replica rejection;
- rollback after reservation or transfer failure;
- archetype migration with columns placed in different storages;
- world destruction and explicit cloning with in-flight work.

Multi-storage integration tests should use deterministic fake asynchronous
backends as well as real devices. GPU tests should be capability-gated, while
the coherence state machine is always tested in CI with host memory.

## Benchmark plan

Retain the existing CPU baselines and add:

- coordinator overhead for an already-prepared host query;
- query planning cost by archetype and component count;
- host-to-device, device-to-host, and peer transfer bandwidth and latency;
- transfer coalescing versus individual columns;
- alternating host/GPU producer-consumer workloads;
- same-GPU system chains proving no redundant transfers;
- structural migration with host-only, device-only, and replicated columns;
- break-even entity counts for host versus GPU execution;
- overlap of kernels, transfers, and independent host systems.

Performance acceptance should focus on plans, transfers, and whole query loops,
not isolated backend method calls.

## Rejected alternatives

### Parameterize `Archetype` by one storage backend

This makes storage swappable but not simultaneous. An entity would still live
in exactly one backend, and a query needing components from two backends would
need migration or an entity join. It also leaves coherence outside the model.

### Give each component type one permanent storage

Permanent partitioning supports simple CPU/GPU splits but cannot move hot data,
replicate read-mostly columns, or support two GPUs. Queries still need a common
row and transfer protocol, so this is better expressed as placement policy.

### Make `get_component` a backend trait method

Per-element dynamic dispatch would harm the main CPU loop and still could not
return one reference type for host and device memory. Whole-column prepared
views are the appropriate boundary.

### Use unified memory as the abstraction

Unified memory may be one backend capability, not the architecture. It does not
exist uniformly across devices, does not express data hazards, and can turn
placement mistakes into unpredictable page migration.

### Keep two complete worlds and synchronize entities

Independent worlds duplicate entity identity and archetype topology. Their row
orders diverge after structural changes, forcing expensive joins and complex
conflict resolution. One logical world with several physical storages provides
a single source of truth.

## Open questions

- What exact Mojo generic shape preserves convenient `World[Position, ...]`
  construction while allowing a custom compile-time storage set?
- Should the canonical entity sequence remain a `List[Entity]`, move to a
  pointer-stable host container, or become coordinator-managed metadata?
- Which Mojo traits precisely prove a component safe for device buffers and
  kernels across supported GPU vendors?
- Should host `World.get` always create a replica, or allow a policy that rejects
  accidental device-to-host transfers?
- What fence type can erase CUDA, HIP, and synchronous host completion without
  allocation in common paths?
- Is versioning per full archetype column sufficient, or do measured workloads
  justify fixed-size dirty chunks?
- Should storage placement be fixed in the world configuration, dynamically
  adjustable, or both with a static upper bound on storage types?

These questions affect API shape and optimization, but not the central model:
one logical entity/archetype topology, shared row coordinates, backend-owned
physical columns, and coordinator-managed coherence among simultaneous
storages.
