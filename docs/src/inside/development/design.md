+++
type = "docs"
title = "Design and evidence map"
weight = 7
+++

The canonical records stay at their repository paths. Links here resolve at
the same revision as the generated API, preserving front matter, supersession,
cross-links, and durable evidence. We do not infer implementation from acceptance.

| Source | Authority and use |
| --- | --- |
| {{< repo "docs/design/README.md" "Design index" >}} | Complete ADR index, lifecycle meanings, metadata schema, and recording workflow. |
| {{< repo "docs/design/requirements.md" "ECS requirements" >}} | Accepted contracts with evidence and explicit implementation gaps. |
| {{< repo "docs/design/architecture.md" "Repository architecture map" >}} | Source-level overview; [published architecture](../../architecture) expands current mechanisms. |
| {{< repo "docs/development.md" "Development reference" >}} | Canonical coding/docstring standards and detailed platform workarounds. |
| {{< repo "GLOSSARY.md" "Glossary" >}} | Shared terminology for composition, storage, execution, and ownership. |
| {{< repo "docs/roadmap.md" "Roadmap" >}} | Unfinished work and priorities. |
| {{< repo "changelog.md" "Changelog" >}} | Completed release history. |

## Decisions

The statuses below identify how to read the records; qualifications in their
front matter remain authoritative. Current behavior is checked against source
and tests in [architecture](../../architecture).

| Records | Status and boundary |
| --- | --- |
| {{< repo "docs/design/decisions/0001-locked-entity-selections.md" "0001 selections" >}}, {{< repo "docs/design/decisions/0002-gpu-system-execution.md" "0002 device execution" >}}, {{< repo "docs/design/decisions/0003-grid-stride-entity-iteration.md" "0003 grid stride" >}}, {{< repo "docs/design/decisions/0004-scoped-selection-errors.md" "0004 errors" >}} | Accepted; current selection/execution foundations. |
| {{< repo "docs/design/decisions/0005-filtered-spatial-row-reordering.md" "0005 spatial ordering" >}}, {{< repo "docs/design/decisions/0010-spatial-classifier-maintenance.md" "0010 full maintenance" >}} | Superseded by 0012; retain historical classification/movement rationale. |
| {{< repo "docs/design/decisions/0006-partitioned-spatial-archetype-storage.md" "0006 partitions" >}}, {{< repo "docs/design/decisions/0008-dirty-entity-spatial-classification.md" "0008 dirty identities" >}}, {{< repo "docs/design/decisions/0009-typed-row-permutation-foundation.md" "0009 typed movement" >}}, {{< repo "docs/design/decisions/0012-deferred-spatial-maintenance.md" "0012 deferred maintenance" >}} | Accepted; current spatial foundations. |
| {{< repo "docs/design/decisions/0007-special-cluster-component.md" "0007 special Cluster component" >}} | Rejected; not a component users must add. |
| {{< repo "docs/design/decisions/0011-pr-performance-regression-checks.md" "0011 regression checks" >}} | Accepted; [gate operation](../regression) describes the implemented checker. |
| {{< repo "docs/design/decisions/0013-cluster-local-partition-blocks.md" "0013 bounded blocks" >}} | Superseded by 0014; the historical 256-row cap is not current. |
| {{< repo "docs/design/decisions/0014-growable-cluster-stores.md" "0014 growable stores" >}} | Accepted; current partition layout. |
| {{< repo "docs/design/decisions/0015-host-device-execution-terminology.md" "0015 terminology" >}} | Superseded by 0023; preserves beta spelling migration. |
| {{< repo "docs/design/decisions/0016-kernel-memory-synchronization.md" "0016 synchronization" >}} | Accepted, partially implemented; standalone primitives exist, dedicated kernel bindings and collection domains do not. |
| {{< repo "docs/design/decisions/0017-deferred-kernel-access.md" "0017 deferred access" >}} | Proposed; no callable deferred-access API. |
| {{< repo "docs/design/decisions/0018-portable-resource-adapters.md" "0018 adapters" >}} | Superseded by 0020 and extended by 0022; preserve source/view and lifetime rationale. |
| {{< repo "docs/design/decisions/0019-threaded-host-execution.md" "0019 threaded execution" >}} | Superseded by 0020; its feasibility evidence is historical. |
| {{< repo "docs/design/decisions/0020-declared-plain-values.md" "0020 plain values" >}} | Accepted; threaded execution remains experimental. |
| {{< repo "docs/design/decisions/0021-skip-unchanged-device-uploads.md" "0021 device-copy reuse" >}}, {{< repo "docs/design/decisions/0022-mutable-adapted-resources.md" "0022 mutable adapters" >}} | Accepted, experimental; implemented contracts are checked against transfer and adapter tests. |
| {{< repo "docs/design/decisions/0023-explicit-execution-backend.md" "0023 explicit targets" >}}, {{< repo "docs/design/decisions/0024-locked-storage-ranges.md" "0024 storage ranges" >}} | Accepted; current target selection and bounded ranges. |

## Research and historical evidence

Research describes the revision and question it investigated. Old `on_device`
spellings, mutable-adapter experiments, or a recommended design are not current
APIs. A probe may depend on its recorded toolchain rather than the current one.

| Repository evidence | Scope |
| --- | --- |
| {{< repo "docs/design/research/host-thread-execution.md" "Host-thread investigation" >}} | Feasibility findings and prototype measurements; not the implemented engine. Companion {{< repo "docs/design/research/host-thread-dispatch-probe.mojo" "dispatch probe" >}} and {{< repo "docs/design/research/host-thread-benchmark.mojo" "benchmark" >}} retain that experiment. |
| {{< repo "docs/design/research/gpu-synchronization.md" "GPU synchronization survey" >}} | Upstream primitive/backend evidence supporting 0016, with coverage limitations. |
| {{< repo "docs/design/research/apple-gpu-publication-ordering.md" "Apple publication ordering" >}} | M4 correctness/performance evidence for release-store/acquire-load publication. |
| {{< repo "docs/design/research/entity-range-migration.md" "Storage range migration" >}} | Cursor-sharing evidence and timing samples affected by concurrent builds; no controlled speedup claim. |
| {{< repo "docs/design/research/struct-constraints.md" "Struct constraint audit" >}} | Mojo 1.0 declaration invariants, proof limits, and intentional exclusions. |
| {{< repo "docs/design/research/reference-invalidation-probe.mojo" "Reference invalidation probe" >}} | Escaped-reference behavior motivating explicit device-copy invalidation. |
| {{< repo "docs/design/research/resource-view-probe.mojo" "Resource-view probe" >}}, {{< repo "docs/design/research/resource-trait-dispatch-probe.mojo" "trait-dispatch probe" >}} | Resource descriptor and trait-dispatch experiments; production behavior comes from current adapters/tests. |

[Measurement reports](../reports) preserve historical benchmark material with
its environment, method, and missing metadata called out. Thesis figures supply
visual vocabulary; their adaptation is recorded in the
{{< repo "docs/figures/README.md" "figure catalog" >}}. Thesis-specific systems,
memory headers, bounded layouts, or branch experiments establish no current
Larecs guarantee.
