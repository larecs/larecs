# Larecs

## Language

**Logical archetype**:
The group of entities sharing the same component composition, regardless of
their physical placement.

**Physical store**:
One contiguous row collection belonging to a logical archetype. Spatial
partitioning can give one logical archetype multiple physical stores.

**Kernel chunk**:
A contiguous subset of one matching physical-store range or exact selected
range, assigned to one kernel invocation.
_Avoid_: Archetype, when referring to only part of a store.

**Threaded host execution**:
Host kernel execution whose independent chunks may run concurrently, with the
enclosing run completing only after all its chunks finish.
_Avoid_: Parallel systems, when only chunks within one run are concurrent.

**Kernel view**:
A resource's kernel-facing representation, distinct from its owning source.
It describes the data available to the kernel on its execution target.
_Avoid_: Resource owner, when referring to the view.

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
