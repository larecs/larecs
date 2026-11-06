---
title: Filters, queries and selections
type: docs
---

{{< api Filter >}} combines membership and kernel permissions at compile time. The common form `Filter().include[Position].read[Velocity]()` requires `Position` and `Velocity`, grants read-write access to `Position`, and grants read-only access to `Velocity`. The trailing `()` constructs the final filter value.

| API | Contract |
| --- | --- |
| {{< api Filter.include >}}, {{< api Filter.read >}}, {{< api Filter.write >}} | Include component types with read-write, read-only or set-only access. A write-only kernel must initialize every selected output row. |
| {{< api Filter.exclude >}}, {{< api Filter.exclusive >}} | Exclude listed types, or match exactly the included composition. `exclusive` resets earlier exclusions; its generated declaration describes composition. |
| {{< api HostStorage.query >}} | `world.storage.query[filter]()` creates a read-only query holding a structural lock. Release it before structural mutations. |
| {{< api ArchetypeRowAccessor >}} | A borrowed row view; `get_entity()` returns a durable handle. Component references remain tied to the row and storage lifetime. |
| {{< api EntityRange >}} | A physical store index, first row, and row count; it describes a bounded interval, not a list of handles. |
| {{< api SystemContext.add_entities >}} | `with context.add_entities[Position](count) as selected:` creates an exact scoped selection. Negative counts raise; zero creates an empty selection. |
| {{< api EntitySelection.run >}} | Runs only the selection's retained ranges. Exiting the scope releases its structural locks, including when the body raises. |

Queries inspect rows; kernels mutate components according to their filter. Selections restrict kernel work to the rows returned by the structural operation. See [queries and iteration](../../guide/queries_iteration) for complete examples and query copy/move behavior.
