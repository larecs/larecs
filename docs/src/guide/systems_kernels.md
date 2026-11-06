+++
type = "docs"
title = "Systems and kernels"
weight = 3
+++

Run application behavior through a system and update matching particles with a
kernel. The [movement tutorial](../../start/first_simulation) provides the complete program.

{{< example file="particles/movement.mojo" region="kernel" >}}
{{< example file="particles/movement.mojo" region="system" >}}
{{< example file="particles/movement.mojo" region="scheduler" >}}

## Access declarations

{{< api Filter >}} describes required components and access. `include` grants
read-write access, `read` grants immutable access, and `exclude` rejects entities
with that component. [`Filter.exclusive`](https://github.com/larecs/larecs/blob/d7629334a68981f32c0399e5e4be5496256b7ae5/src/larecs/filter.mojo#L177) rejects extra components.
The kernel's {{< api KernelContext >}} supplies only declared component access;
requesting an undeclared component through `get` fails compilation.
{{< api Resources >}} independently declares resource access.

{{< api SystemContext.run >}} calls a host kernel for each non-empty matching
physical store: a group of stored rows with the same component set. An archetype
can have several such stores. Put per-entity work inside the loop. With no
matching entities, no kernel body runs. Calls complete before the next system
proceeds.

### Write-only components

{{< example file="particles/lifecycle.mojo" region="write_only" >}}

[`Filter.write`](https://github.com/larecs/larecs/blob/d7629334a68981f32c0399e5e4be5496256b7ae5/src/larecs/filter.mojo#L134) permits {{< api EntityAccessor.set >}} and rejects
`get`: initialize the component for every processed row before reading it in a
later kernel. The creation program runs this kernel before movement.
For device execution, read access uploads values, write access downloads results,
and read-write access does both; write-only values are not uploaded.
See [execution details](../systems_scheduler#device-execution) for target limits.

## Lifecycle and order

{{< api System >}} supplies `initialize`, `update`, and `finalize` hooks.
{{< api Scheduler.run >}} initializes all systems, updates them for each step,
then finalizes them, in registration order within each phase. Errors propagate;
`run` does not guarantee finalization after a failed hook. For repeated stepping,
use `initialize`, `update(steps=...)`, and `finalize` explicitly.

## Inspecting entities

Use {{< api HostStorage.query >}} for read-only inspection outside kernels.
The full [creation example](../../start/growing_simulation) inspects the marker
before scheduling:

{{< example file="particles/lifecycle.mojo" region="inspection" >}}

The example copies the query to show that the copy has its own cursor.
Consuming both with `^` ends their locks before the scheduler takes the world.

A query's filter requires or excludes component types; `exclusive` restricts it
to exactly the included set. Query rows are {{< api ArchetypeRowAccessor >}}
values, not entity handles. `get` reads a component guaranteed by the filter;
`get_entity` retrieves the persistent handle. A query remains read-only even
when its filter uses `include`. Use a kernel to update matching entities.

### Query lock lifetime, copies, and moves

A live query prevents structural changes, even when empty or exhausted. Consume
it in a short loop or let it be destroyed before mutation. A copy starts at the
same position with an independent cursor and structural lock; a move transfers
the existing lock. Keep no row accessor beyond its query or across structural
changes. These locks prevent invalidation; they are not thread mutexes.

### Handles, accessors, queries, selections, and ranges

| Value | Copy and move | Structural lock | Access |
| --- | --- | --- | --- |
| Entity handle | Copyable and movable | None | Identifies an entity for storage calls; survives row movement, not deletion |
| Query row accessor | Movable, noncopyable | Relies on the enclosing query | Reads query components; discard before structural changes |
| Query | Copies have independent cursors and locks; moves transfer the lock | Retained after exhaustion, even for empty results | Read-only traversal |
| Entity selection | Movable, noncopyable | Until release, destruction, or manager exit, including empty selections | Component changes and filtered kernel execution on exactly its members |
| Storage batch range ({{< api HostStorage.add_entities >}}) | Copies have independent cursors and locks; moves transfer the lock | Retained after exhaustion, even for empty results | Low-level traversal and mutable `unsafe_get`; no selection `run` |

See [Structural changes](../structural_changes) for scoped mutation and
{{< api HostStorage >}} for storage batch operations.

## Troubleshooting

A missing required resource makes `run` raise: add it during setup. A component
access compile error usually means the filter does not guarantee that type or
grants only read access. A locked-world error means a query or selection still
lives; end its scope before unrelated structural work.

For supported lower-level traversal, see {{< api HostStorage >}} and
{{< api ArchetypeRowAccessor >}}. For advanced execution, see
[Systems and the scheduler](../systems_scheduler).
