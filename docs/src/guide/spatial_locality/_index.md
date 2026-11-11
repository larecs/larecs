+++
type = "docs"
title = "Spatial locality"
weight = 8
+++

[Maintain particle locality](maintain) groups the particles of each grid cell
in memory without changing entity identity, and selects exactly one cell's
particles. Start with [kernel access](../systems_kernels) and
[scoped selections](../structural_changes).

For classifier and maintenance contracts, use the
[spatial reference](../../reference/spatial_sync).
[Spatial maintenance internals](../../inside/architecture/spatial) explains dirty
tracking, classification, and partition placement.
