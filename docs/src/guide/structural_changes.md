+++
type = "docs"
title = "Structural changes"
weight = 4
+++

Create a batch, change its component composition, and run only those particles
with a scoped selection. The [creation tutorial](../../start/growing_simulation)
provides the complete runnable program and its observable result.

{{< example file="particles/lifecycle.mojo" region="write_only" >}}
{{< example file="particles/lifecycle.mojo" region="lifecycle" >}}

## Values versus structure

Updating `Position.x` through a kernel changes a value. Creating or deleting
entities and adding or removing component types changes structure. Structural
changes can move rows: discard old component references and row accessors,
then look up components again by entity handle.

## Exact selection membership

{{< api SystemContext.add_entities >}} returns exactly the new rows.
{{< api SystemContext.add >}}, {{< api SystemContext.remove >}}, and
{{< api SystemContext.replace >}} select rows matching an operation filter.
Their [EntitySelection](https://github.com/larecs/larecs/blob/d7629334a68981f32c0399e5e4be5496256b7ae5/src/larecs/system.mojo#L568) results retain those identities through
composition changes. Selection `add`, `remove`, and `replace` mutate the same
selection in place and return nothing. `remove` removes components, not entities.
Selection `run` intersects that membership with the kernel's filter; it never
expands to other particles that happen to have the same components.

## Scoped cleanup and empty selections

Use `with` to release the structural lock on normal exit, error, or early return.
For an existing selection, transfer it into the manager with `with selection^`.
A selection is movable and noncopyable. Outside a manager, consuming `release`
or destruction releases it. Inside a manager the lock lasts until scope exit.
Even zero-count creation returns a locked selection; an empty matching run
invokes no kernel body. Negative counts raise.

## Delete particles after releasing the selection

{{< api HostStorage.remove_entity >}} deletes one handle;
{{< api HostStorage.remove_entities >}} deletes every filter match. The example
removes the marker only after leaving the creation scope. In a system, use
`context.world[].storage` for deletion: `SystemContext` has no entity-deletion
method. Unrelated structural operations while a query or selection lives raise a
locked-world error.
Do not solve that error by keeping references across the scope boundary.

For setup, {{< api HostStorage.add_entities >}} and storage component operations
remain supported. Their locked row ranges are lower-level results, with no
selection `run` method; use system selections for application batches.
