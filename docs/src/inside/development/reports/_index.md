+++
type = "docs"
title = "Measurement reports"
weight = 8
+++

These scoped records retain benchmark investigations and their limitations.
They describe the recorded hardware, toolchain, revision, and workload rather
than promising application performance. Missing metadata is identified explicitly.
Use the [methodology](../benchmarks) for new measurements and the
[regression reference](../regression) for current gate operation.

| Report | Evidence boundary |
| --- | --- |
| [Selections and shared host setup](selection) | Early incomplete sample, controlled M4 setup comparison, and range-migration evidence. |
| [Threaded host execution](threaded) | Implemented engine on Ryzen 5850U; separate historical prototype link. |
| [Synchronization protocol](synchronization) | Driver timing boundaries; no recorded timing result. |
| [Deferred dirty classification](dirty_spatial) | M4 sparse/full comparisons, marking costs, and default-path gate evidence. |
| [Partition layouts](partitions) | Linux growable stores and explicitly historical macOS bounded blocks. |
| [Resource execution](resources) | M4 source/adapter and staged-publication costs. |
| [AoS plotting workflow](aos) | Dynamic publishing-run artifact; environment limits and raw-result access. |
| [Regression-check runtime](regression) | Initial local and hosted gate costs; no cross-platform speed comparison. |

Additional investigations retain their original paths in the
[design and evidence map](../design), including host-dispatch prototypes,
Apple GPU publication, and storage-range migration.
