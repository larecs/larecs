+++
type = "docs"
title = "Guides"
weight = -1

[sidebar]
open = true
+++

Complete [Your first simulation](../start/first_simulation) before choosing a
task. Each group below leads to implemented guides and checked particle stages.

| Group | Tasks |
| --- | --- |
| Data model | [Model entities and components](data_model). |
| Systems and kernels | [Declare kernel access, order systems, and inspect entities](systems_kernels). |
| Structural changes | [Create and change batches with scoped selections](structural_changes). |
| Resources | [Share values with resources](shared_resources). |
| [Execution](execution) | Select host/device, pass captures, bind portable resources, run host chunks, reuse device copies, and coordinate shared output. |
| [Spatial locality](spatial_locality) | Classify particles, maintain placement explicitly, and select exact clusters. |
| [Performance](performance) | Validate work, profile dominant systems, and measure complete steps. |

The earlier [systems](systems_scheduler), [resource operations](resources),
[spatial clustering](spatial_clustering), [synchronization](synchronization),
and [benchmark](benchmarks) pages remain accessible. Use
[compatibility and status](../reference/compatibility) for experimental limits
and [errors and migration](../reference/errors) for diagnostics.
