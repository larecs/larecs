+++
type = "docs"
title = "Architecture"
weight = 1
+++

We separate world-owned state from the temporary views used to execute work.
These explanations trace the implementation behind the application contracts.

| Mechanism | Explanation |
| --- | --- |
| [Execution and ownership](ownership) | Scheduler phases, world ownership, system borrows, and kernel views. |
| [Archetypes, columns, and locations](storage) | Logical composition, physical stores, typed lifecycles, and structural movement. |
| [Queries, selections, and ranges](iteration) | Shared metadata, independent cursors, exact membership, and structural guards. |
| [Work mapping](execution) | Sequential ranges, threaded chunks, and packed grid-stride execution. |
| [Bindings, transfers, and revisions](transfers) | Source leases, adapter views, publication, and device-copy validity. |
| [Spatial maintenance](spatial) | Dirty identities, classification boundaries, permutations, and partition placement. |
| [Synchronization internals](synchronization) | Atomic scope, guard state, confinement, and unsupported bindings. |

The [design and evidence map](../development/design) links the existing
requirements, decisions, and research with their status intact. An accepted
decision can contain unimplemented parts; the explanations above describe
verified source behavior. Experimental API status stays in
[compatibility and status](../../reference/compatibility).
