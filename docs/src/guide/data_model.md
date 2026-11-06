+++
type = "docs"
title = "Data model"
weight = 2
+++

Use entities for identities and components for per-particle values. Start with
the complete [movement program](../../start/first_simulation).

{{< example file="particles/movement.mojo" region="components" >}}
{{< example file="particles/movement.mojo" region="world" >}}

## Entity identity

An {{< api Entity >}} is a copyable ID and generation, not a component address.
Keep the handle to find the particle again through {{< api HostStorage.get >}}.
Deletion invalidates that identity and advances its generation before ID reuse.
Handles belong to their world: do not use a handle in another world.

## Components and tags

A component conforms to `ComponentType` (`Copyable & Deinitable`); each entity has at most one value
of each component type. A tag is a component with no fields: its presence carries
the information. Filters can require or exclude it just like a data component.

## World type packs

{{< api World >}} declares all allowed component types at compile time.
`World[Position, Velocity]` allows either, both, or neither on an entity.
Resources have separate storage and do not belong in that component pack.
Entities with the same component set belong to an archetype; you need no storage
layout knowledge to create them or run systems over them.

Use {{< api HostStorage.add_entity >}} for initial setup and individual creation.
Use [systems and kernels](../systems_kernels) for repeated simulation work and
[scoped structural changes](../structural_changes) for batches.

## References after changes

Changing `Position.x` changes a value. Adding or removing a component changes
composition and may move rows. Creation, deletion, and other structural changes
can invalidate component references and row accessors. Retain entity handles,
then reacquire references after mutation. Never use a row index as identity.
