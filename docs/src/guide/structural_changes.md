+++
type = "docs"
title = "Create and remove entities in batches"
weight = 4
+++

Create a batch of entities, change their components, and run kernels on only
those entities with a scoped selection. Then remove entities once the scope
ends. [Create and remove particles](../../start/growing_simulation) runs this
code and checks the result.

{{< example file="particles/lifecycle.mojo" region="write_only" >}}
{{< example file="particles/lifecycle.mojo" region="lifecycle" >}}

`context.add_entities` creates three particles and returns a selection of
exactly those three. Inside the `with` block, `selected.add`, `selected.run`,
and other selection methods act on those particles only. After the block,
`remove_entities` deletes every particle with a `Position` and no `Velocity`.

## Values versus structure

Assigning `position.x` in a kernel changes a value. Creating or deleting an
entity, or adding or removing a component type, changes the world's
*structure*. A structural change can move rows in memory. After one, discard
component references and row accessors, and look components up again by
entity handle.

## Select exactly the entities you change

These operations return an `EntitySelection`:

- {{< api SystemContext.add_entities >}} selects exactly the new entities.
- {{< api SystemContext.add >}}, {{< api SystemContext.remove >}}, and
  {{< api SystemContext.replace >}} select the entities that match the filter
  you pass.

A selection keeps its members when their components change. Its `add`,
`remove`, and `replace` methods change the members' components in place and
return nothing; `remove` removes components, not entities. Its `run` method
visits the members that also match the kernel's filter, and never other
entities with the same components.

[`EntitySelection`](https://github.com/larecs/larecs/blob/d7629334a68981f32c0399e5e4be5496256b7ae5/src/larecs/system.mojo#L568)
documents every selection method.

## End the structural lock with `with`

A selection holds a structural lock until it is released. While any lock is
held, unrelated entity creation, entity deletion, and component additions or
removals raise a locked-world error.

- Use `with` so the lock ends when the block ends, including on an error or an
  early return.
- To scope a selection you already hold, write `with selection^ as selected:`.
- Inside `with`, the lock lasts until the block ends, even if you release the
  bound selection earlier.
- Without `with`, the lock ends when you call the consuming `release` method
  or the selection is destroyed.

Selections are movable but not copyable.

## Empty and invalid batches

- `add_entities` with `count=0` returns an empty selection that still holds a
  lock.
- Running a kernel on an empty selection never runs the kernel body.
- A negative `count` raises.

## Remove entities

{{< api HostStorage.remove_entity >}} deletes one entity by handle, and
{{< api HostStorage.remove_entities >}} deletes every entity that matches a
filter. `SystemContext` has no method for deleting entities, so a system
deletes through `context.world[].storage`, as `Spawn` does. Delete only after
the `with` block ends; while the selection's lock is held, deletion raises a
locked-world error.

## Create entities outside a system

During setup, {{< api HostStorage.add_entities >}} creates a batch directly in
the world. It returns a locked row range for direct component access, not a
selection, and has no `run` method. Inside systems, use
`context.add_entities` to get a selection.

## Next steps

- [Update entities with systems and kernels](../systems_kernels#compare-handles-queries-and-selections)
  compares selections with queries and entity handles.
- [Adding and removing entities](../adding_and_removing_entities) shows the
  individual storage operations.

[Structural transitions](../../inside/architecture/storage#structural-transitions-and-identity)
traces typed movement, swap-removal, and entity-location repair.
