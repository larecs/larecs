+++
type = "docs"
title = "Execution"
weight = 6
+++

Choose how a checked particle kernel receives data and where it runs. Complete
[Your first simulation](../../start/first_simulation) and
[Share time and configuration](../../start/shared_configuration) first.
Each guide is an optional, independently runnable stage.

| Task | Result |
| --- | --- |
| [Execute on a device](device) | Select a target explicitly and check its results against host execution. |
| [Pass local values to kernels](captures) | Use lexical host borrows or ordered explicit capture slots. |
| [Use portable resources](portable_resources) | Keep owning collections on the host and bind target-local kernel views. |
| [Run threaded host kernels](threaded) | Process independent chunks and verify sequential parity. |
| [Reuse unchanged device copies](copy_reuse) | Skip unchanged uploads while preserving eager copy-back. |
| [Coordinate shared writes](shared_writes) | Choose per-row output, single-writer reduction, or supported standalone primitives. |

[Compatibility and status](../../reference/compatibility) records the development
version and experimental boundaries. [Errors and migration](../../reference/errors)
indexes common failures; each stage gives its own restrictions and recovery steps.

[Work mapping](../../inside/architecture/execution) explains physical ranges,
threaded jobs, and packed grid-stride execution.
