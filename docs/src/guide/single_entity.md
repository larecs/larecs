+++
type = "docs"
title = "Change one entity's components"
weight = 4
+++

Read, change, add, remove, and replace the components of one entity through
its handle. Use these operations in setup code, in tests, or in a system that
handles a few known entities. To change every entity that matches a filter,
use a [kernel](../systems_kernels) or a
[batch operation](../structural_changes) instead.

The examples use the particle components from
[Your first simulation](../../start/first_simulation) and one more component,
`Frozen`, which replaces `Velocity` when a particle stops:

{{< example file="particles/single_entity.mojo" region="components" >}}

{{< example file="particles/single_entity.mojo" region="setup" >}}

`walker` has a position and a velocity; `marker` has only a position. Inside a
system, call the same methods on `context.world[].storage`.

## Read and change a component

{{< example file="particles/single_entity.mojo" region="get" >}}

{{< api HostStorage.get >}} returns a mutable reference to the component. You
can change a field through it or assign a whole new value. The reference
borrows the world, so get it again after you add or remove components.

## Check whether an entity has a component

{{< example file="particles/single_entity.mojo" region="has" >}}

`get` raises when the entity lacks the component. Check with
{{< api HostStorage.has >}} first when the composition is not known.

## Set several components at once

{{< example file="particles/single_entity.mojo" region="set" >}}

{{< api HostStorage.set >}} assigns new values to components the entity already
has. It does not add missing components.

## Add and remove components

{{< example file="particles/single_entity.mojo" region="add_remove" >}}

{{< api HostStorage.add >}} and {{< api HostStorage.remove >}} accept any
number of components. Each call is a
[structural change](../structural_changes#values-versus-structure): the entity
moves to the storage for its new composition.

## Replace components in one move

{{< example file="particles/single_entity.mojo" region="replace" >}}

{{< api HostStorage.replace >}} names the components to remove, and
{{< api Replacer.by >}} supplies the components to add. The entity moves to its
new storage once. A separate `remove` followed by `add` moves it twice.

## Failure behavior

{{< example file="particles/single_entity.mojo" region="failures" >}}

| Situation | Result |
| --- | --- |
| The entity was removed | Every operation on its handle raises. |
| `get`, `set`, or `remove` names a component the entity lacks | The call raises. |
| `add` names a component the entity already has | The call raises. |
| A query or selection holds a structural lock | `add`, `remove`, and `replace` raise; release the query or close the `with` block first. |

## Run the complete program

{{< example file="particles/single_entity.mojo" full=true >}}

Run it from the repository root:

```sh
pixi run mojo run -I src examples/particles/single_entity.mojo
```

It prints `PASS: single-particle reads, changes, and composition changes`.

## Next steps

- [Create and remove entities in batches](../structural_changes) changes many
  entities with one call.
- [Update entities with systems and kernels](../systems_kernels) runs the same
  change on every matching entity.
