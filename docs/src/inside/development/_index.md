+++
type = "docs"
title = "Development"
weight = 2
+++

We change ECS contracts through the existing requirements and ADR workflow,
then verify implementation, examples, and measured costs together.

| Task or lookup | Material |
| --- | --- |
| [Set up, build, and test](setup) | Locked environments, package builds, focused checks, and platform failures. |
| [Test and hardware coverage](checks) | Compile contracts, sanitizer/debug markers, and the meaning of a hardware skip. |
| [Change an ECS contract](contracts) | Existing design records, implementation evidence, benchmark obligations, and documentation. |
| [Build documentation and figures](documentation) | Compiler JSON, checked excerpts, Astro/Starlight, API verification, and reproducible assets. |
| [Measure an implementation change](benchmarks) | Workloads, timing boundaries, paired samples, and retained evidence. |
| [Operate regression checks](regression) | Baselines, case manifests, thresholds, confirmation, and failure reports. |
| [Design and evidence map](design) | Repository requirements, ADR statuses, research, coding standards, and historical material. |
| [Measurement reports](reports) | Scoped investigations with hardware/compiler/revision and limitations. |

The [architecture explanations](../architecture) describe current mechanisms.
Tasks and priorities remain in {{< repo "docs/roadmap.md" "the roadmap" >}};
completed releases remain in {{< repo "changelog.md" "the changelog" >}}.
