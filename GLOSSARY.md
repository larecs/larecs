# Larecs

## Language

**Logical archetype**:
The group of entities sharing the same component composition, regardless of
their physical placement.

**Physical store**:
One contiguous row collection belonging to a logical archetype. Spatial
partitioning can give one logical archetype multiple physical stores.

**Component column**:
A contiguous allocation of complete values of one component type in a physical
store. Fields such as `Position.x/y` remain inside each component value.

**Store incarnation**:
A number assigned to each new physical store, never reused within its host
storage. Device-copy records use it to distinguish recycled directory slots.

**Kernel chunk**:
A contiguous subset of one matching physical-store range or exact selected
range, assigned to one kernel invocation.
_Avoid_: Archetype, when referring to only part of a store.

**Thin kernel**:
A named `def` function that `run` receives as a compile-time parameter, as in
`context.run[move]()`, and that captures no local variables. Threaded host and
device execution accept only thin kernels.
_Avoid_: Kernel function, when the distinction from a closure matters.

**Lexical closure**:
A nested `def` that borrows local variables through a capture list, such as
`{imm scale, mut visits}`, and is passed to `run` as a value. Lexical closures
run only on the sequential host.

**Capture slot**:
One ordered entry of a kernel's `Captures` declaration, bound to a local value
with `read_capture` or `mut_capture` when the kernel runs.

**Grid-stride iteration**:
The device row loop in which each thread starts at its global thread index and
advances by the number of launched threads, so every packed row is visited
exactly once.

**Threaded host execution**:
Host kernel execution whose independent chunks may run concurrently, with the
enclosing run completing only after all its chunks finish.
_Avoid_: Parallel systems, when only chunks within one run are concurrent.

**Kernel view**:
A resource's kernel-facing representation, distinct from its owning source.
It describes the data available to the kernel on its execution target.
_Avoid_: Resource owner, when referring to the view.

**Resource source**:
The host-owned value stored under a resource type. An adapter binds its kernel
view for the selected target and declared access.

**Portable resource**:
A resource source that names a `ResourceAdapter`, which builds a kernel view
for the selected target, so owning data can reach threaded and device kernels.
_Avoid_: Adapted resource, adapter-backed resource.

**Resource lease**:
An invocation's retained access to a source, preventing reentrant lookup,
replacement, or removal until completion. It does not synchronize workers'
shared writes or protect against previously escaped aliases.

**Staging buffer**:
Invocation-owned host memory that holds upload snapshots or downloaded device
output until publication.
_Avoid_: Staging store, which holds rows awaiting spatial maintenance.

**Publication**:
Writing a device call's downloaded outputs from staging buffers to their host
destinations, after successful synchronization.

**Spatial classifier**:
A world's registered `SpatialClassifier` that computes a cluster key for each
eligible entity during spatial maintenance.

**Cluster key**:
An application classifier's UInt64 identity for a locality group. Equal keys
identify a cluster; key proximity does not establish exact spatial neighbors.

**Partition**:
In partition mode (`partitioned=True`), the growable physical store that holds
one cluster of one logical archetype.

**Staging store**:
A partitioned logical archetype's physical store for rows awaiting explicit
spatial maintenance. Ordinary matching queries and kernels still visit them.

**Dirty entity**:
An entity whose classifier inputs may have changed since its key was last
computed. The next spatial maintenance pass reclassifies it.

**Device copy**:
The device-held bytes of one resource or of one store's component column,
last transferred to or from the host.
_Avoid_: Device cache, when referring to contents rather than allocations.

**Revision**:
A per-item number that Larecs advances whenever a resource or a store's
component column may have changed on the host.
_Avoid_: Generation (an entity's recycling count), version.

**Stale device copy**:
A device copy whose recorded revision differs from the item's current revision.

**Tag**:
A component type with no fields; its presence on an entity carries the
information.

**Structural change**:
Creating or deleting an entity, or adding or removing a component type on one.
Structural changes can move rows; value assignments do not.

**Structural lock**:
A guard, held by a live query, storage batch range, or entity selection, that
makes unrelated structural changes raise a locked-world error.
_Avoid_: Mutex, lock, when referring to thread synchronization.

**Entity selection**:
An exact, noncopyable set of entity rows returned by a structural operation,
such as `SystemContext.add_entities`, that holds a structural lock until it is
released.
