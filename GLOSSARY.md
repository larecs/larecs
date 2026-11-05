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
