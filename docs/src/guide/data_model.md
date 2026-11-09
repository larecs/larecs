+++
type = "docs"
title = "Model data with entities and components"
weight = 2
+++

Represent each simulated object as an entity and store its per-object values in
components. This page uses the particles from
[Your first simulation](../../start/first_simulation).

{{< example file="particles/movement.mojo" region="components" >}}
{{< example file="particles/movement.mojo" region="world" >}}

`Position` and `Velocity` are components. `World[Position, Velocity]` declares
the component types the world can store. Each
{{< api HostStorage.add_entity >}} call creates an entity with the given
components and returns its handle.

## Define components

A component is a struct that conforms to
[`ComponentType`](../../larecs#aliases), which requires `Copyable` and
`Deinitable`. `Copyable, Movable` satisfies both. An entity holds at most one
value of each component type.

A component with no fields is a *tag*. Its presence carries the information,
and filters can require or exclude it like any other component.

## Declare the world's component types

{{< api World >}} lists every component type at compile time. An entity of
`World[Position, Velocity]` can have either component, both, or neither: in the
example, `marker` has only a `Position`. Resources live in separate storage and
do not appear in this list.

Larecs groups entities with the same set of components into a *logical
archetype*. You need no knowledge of this layout to create entities or run
systems over them.

## Keep entity handles

An {{< api Entity >}} is a copyable ID and generation, not the address of its
components. Keep the handle to find the entity again, for example with
{{< api HostStorage.get >}}.

- Removing an entity invalidates its handle. Larecs increments the generation
  before it reuses the ID, so an old handle never refers to a new entity.
- A handle belongs to the world that created it. Do not use it with another
  world.
- Structural changes can move an entity's components in memory. Keep the
  handle across [structural changes](../structural_changes), not component
  references or row indices.

## Next steps

- [Update entities with systems and kernels](../systems_kernels) for repeated
  simulation work.
- [Create and remove entities in batches](../structural_changes) for creating
  many entities at once.

[Archetypes, columns, and locations](../../inside/architecture/storage) explains
how logical composition maps to physical stores and typed component lifecycles.
