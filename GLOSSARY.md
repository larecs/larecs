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
