---
title: Spatial APIs and synchronization
type: docs
weight: 5
---

Spatial classification groups entities by application-defined keys. It changes physical placement without changing an entity's component composition or identity. Row ordering and addresses are not persistent entity identities.

| API | Contract |
| --- | --- |
| {{< api SpatialClassifier >}} | Define the classification key for the registered component types. |
| {{< api grid_cell >}} | Convert position coordinates to a grid cell using the supplied cell size. |
| {{< api morton_key_3d >}} | Encode a three-dimensional integer cell as a Morton key within the documented coordinate limits. |
| {{< api AtomicValue >}}, {{< api AtomicView >}} | Own an atomic value or borrow an atomic view; operations expose their memory ordering parameters. |
| {{< api CompareExchangeResult >}} | Reports compare-exchange success and the observed value. |
| {{< api Synchronized >}}, {{< api SyncView >}} | Own guarded state or borrow its view. Use nonblocking `try_read` or `try_write` and check acquisition. |
| {{< api TryAccess >}} | Test `is_acquired()` before consuming the result with `take()`. Keep access within the acquired guard's lifetime. |

The generated declarations define supported value types, origins, mutation rights and memory orderings. See [maintaining particle locality](../../guide/spatial_locality/maintain) and [coordinating shared writes](../../guide/execution/shared_writes) for complete examples. Synchronization does not grant undeclared component/resource access or permit structural mutation during kernel execution.
