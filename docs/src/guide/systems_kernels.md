+++
type = "docs"
title = "Update entities with systems and kernels"
weight = 3
+++

Put repeated simulation work in a system, and let the system run a kernel over
every entity that matches a filter. This page uses the movement code from
[Your first simulation](../../start/first_simulation).

{{< example file="particles/movement.mojo" region="kernel" >}}
{{< example file="particles/movement.mojo" region="system" >}}
{{< example file="particles/movement.mojo" region="scheduler" >}}

`move` is the kernel, `Move` is the system that runs it, and the
{{< api Scheduler >}} calls `Move.update` once per step.

## Declare component and resource access

A {{< api Filter >}} selects entities and sets how the kernel may access their
components:

| Step | Matches | Access through the kernel |
| --- | --- | --- |
| `include[T]()` | Entities with `T` | Read and write with `get` |
| `read[T]()` | Entities with `T` | Read with `get` |
| `write[T]()` | Entities with `T` | Write with `set` only |
| `exclude[T]()` | Entities without `T` | None |
| [`exclusive()`](https://github.com/larecs/larecs/blob/d7629334a68981f32c0399e5e4be5496256b7ae5/src/larecs/filter.mojo#L177) | Only entities without further components | Unchanged |

The kernel's {{< api KernelContext >}} exposes only the declared access.
Calling `get` on a component the filter does not guarantee, or writing through
`read` access, fails to compile. {{< api Resources >}} declares resource access
separately; see [Share values with resources](../shared_resources).

## How often a kernel runs

On the host, {{< api SystemContext.run >}} calls the kernel once for each
non-empty matching *physical store*: a group of rows with the same components.
One logical archetype can have several physical stores. Put per-entity work
inside the `for` loop over the context. With no matching entities, the kernel
body never runs. All calls finish before `run` returns, so the next system sees
the results.

## Write values without reading them

{{< example file="particles/lifecycle.mojo" region="write_only" >}}

[`Filter.write`](https://github.com/larecs/larecs/blob/d7629334a68981f32c0399e5e4be5496256b7ae5/src/larecs/filter.mojo#L134)
permits {{< api EntityAccessor.set >}} and rejects `get`. Set the component on
every row the kernel visits; a later kernel can then read it.
[Create and remove particles](../../start/growing_simulation) runs this kernel
before movement.

For device execution, the access mode decides the transfers: read access
uploads values, write access downloads results, and read-write access does
both. Write-only values are not uploaded. See
[device execution](../execution/device) for target limits.

## Order systems and steps

{{< api System >}} has three hooks: `initialize`, `update`, and `finalize`.
{{< api Scheduler.run >}} initializes all systems, updates them once per step,
and then finalizes them. Within each phase, systems run in the order you added
them.

An error in a hook propagates out of `run`, and `run` does not guarantee that
`finalize` runs afterwards. To step the simulation in several batches, call
`initialize`, `update(steps=...)`, and `finalize` yourself.

## Inspect entities outside a kernel

Use {{< api HostStorage.query >}} to read entities outside a kernel, for
example during setup. [Create and remove particles](../../start/growing_simulation)
inspects the marker before it starts the scheduler:

{{< example file="particles/lifecycle.mojo" region="inspection" >}}

Each query row is an {{< api ArchetypeRowAccessor >}}, not an entity handle.
`get` reads a component the filter guarantees, and `get_entity` returns the
entity's handle. A query is read-only, even when its filter uses `include`; use
a kernel to change values. `exclusive()` restricts a query to entities with
exactly the listed components, so the last assertion counts only `marker`.

A live query holds a structural lock, even after it is exhausted or when it
matched nothing. Consume it in a short loop, or let it go out of scope, before
you create or remove entities. A copy starts at the same position with its own
cursor and lock; a move transfers the existing lock. The example copies the
query to show this, and consumes both with `^` so their locks end before the
scheduler takes the world. Do not keep a row accessor beyond its query or
across structural changes. Structural locks protect references from
invalidation; they are not thread mutexes.

## Compare handles, queries, and selections

| Value | Copy and move | Structural lock | Use |
| --- | --- | --- | --- |
| Entity handle | Copyable and movable | None | Identify an entity in storage calls; survives row movement, not deletion |
| Query row accessor | Movable, not copyable | Held by its query | Read the query's components; discard before structural changes |
| Query | Copy: own cursor and lock. Move: transfers the lock | Until destroyed, even when exhausted or empty | Read-only traversal |
| Entity selection | Movable, not copyable | Until released, destroyed, or its `with` block ends, even when empty | Change components and run kernels on exactly its members |
| Storage batch range ({{< api HostStorage.add_entities >}}) | Copy: own cursor and lock. Move: transfers the lock | Until destroyed, even when exhausted or empty | Low-level traversal and mutable `unsafe_get`; no `run` |

[Create and remove entities in batches](../structural_changes) covers
selections.

## Troubleshooting

| Symptom | Cause and fix |
| --- | --- |
| `run` raises about a missing resource | The kernel declares a resource the world lacks. Add it during setup. |
| Compile error on component access | The filter does not guarantee the component, or grants only `read` access. Adjust the filter. |
| Locked-world error | A query or selection is still alive. End its scope before the structural change. |

## Next steps

- [Execution](../execution) covers captures, portable resources, threaded host
  kernels, and device execution.
- {{< api HostStorage >}} and {{< api ArchetypeRowAccessor >}} document
  lower-level traversal.

[Execution and ownership](../../inside/architecture/ownership) explains scheduler
and context lifetimes; [queries and ranges](../../inside/architecture/iteration)
explains cursor metadata and structural guards.
