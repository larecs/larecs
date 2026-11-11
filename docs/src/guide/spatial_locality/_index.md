+++
type = "docs"
title = "Spatial locality"
weight = 8
+++

[Maintain particle locality](maintain) groups nearby particle data without
changing entity identity. Start with [kernel access](../systems_kernels) and
[scoped selections](../structural_changes). The checked stage compares default
row ordering with opt-in growable cluster stores and exact maintained selection.

For a classifier or maintenance contract, use the
[spatial reference](../../reference/spatial_sync).

[Spatial maintenance internals](../../inside/architecture/spatial) explains dirty
identity queues, classification plans, typed movement, and partition placement.
