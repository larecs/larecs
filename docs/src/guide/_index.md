+++
type = "docs"
title = "Guides"
weight = -1

[sidebar]
open = true
+++

Complete [Your first simulation](../start/first_simulation) before choosing a
task. Each guide extends the particle simulation with one feature.

| Guide | Tasks |
| --- | --- |
| [Model data with entities and components](data_model) | Define components, declare the world, and keep entity handles. |
| [Update entities with systems and kernels](systems_kernels) | Declare kernel access, order systems, and inspect entities. |
| [Change one entity's components](single_entity) | Read, change, add, and remove one entity's components. |
| [Create and remove entities in batches](structural_changes) | Create and change batches with scoped selections. |
| [Share values with resources](shared_resources) | Share values, read owning data on any target, and combine results from many invocations. |
| [Run kernels on threads and devices](execution_backends) | Run threaded host chunks or device launches, pass local values, and reuse device copies. |
| [Maintain particle locality](spatial_locality) | Classify particles, maintain placement, and select exact clusters. |

The [API reference](../larecs) documents every declaration.
