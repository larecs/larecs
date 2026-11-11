---
title: Identity and world
type: docs
weight: 1
---

{{< api World >}} owns the component storage and shared resource storage for a fixed compile-time component type pack. Use `World[Position, Velocity]()` during setup, then pass `world^` to {{< api Scheduler >}} to transfer ownership. The [first simulation](../../start/first_simulation) supplies the complete definitions and an asserted result.

| API | Contract and common form |
| --- | --- |
| {{< api Entity >}} | A handle containing an ID and generation; retain handles rather than row addresses across structural changes. `get_id()` alone does not establish identity after recycling. |
| {{< api HostStorage.is_alive >}} | `world.storage.is_alive(entity)` checks whether the generation still names a live entity. |
| {{< api HostStorage.add_entity >}} | `world.storage.add_entity(Position(0, 0), Velocity(1, 0))` creates an entity and returns its handle. |
| {{< api HostStorage.get >}} | `world.storage.get[Position](entity)` borrows an existing component. Adding, removing or migrating entities can invalidate row references. |
| {{< api HostStorage.set >}} | Replace an existing component value without changing the component set. |
| {{< api HostStorage.replace >}} | `world.storage.replace[Removed]().by(value, entity=entity)` changes the component set. |
| {{< api component.ComponentType >}} | Required component traits; host components can own nontrivial data. Heap ownership adds allocation and lifecycle costs. |

The generated type pages retain exact constructor declarations and overloads. The [compatibility table](../compatibility) distinguishes host component support from device transfer eligibility.
