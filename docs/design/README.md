# Larecs design record

This directory is the source of truth for **accepted ECS requirements and design
decisions**. It explains why an API or invariant exists. The public
[`docs/src/guide/`](../src/guide/) teaches users how to use the library;
the [roadmap](../roadmap.md) tracks unfinished work by priority, and the
[changelog](../../changelog.md) records completed release history.

Start with [requirements](requirements.md) for the current contract and
[architecture](architecture.md) for the component map. Read the relevant
decision record before changing an established behavior:

| Decision                                                        | Status                          | Subject                                                                  |
| --------------------------------------------------------------- | ------------------------------- | ------------------------------------------------------------------------ |
| [0001](decisions/0001-locked-entity-selections.md)              | Accepted                        | Locked entity selections and exact-range execution                       |
| [0002](decisions/0002-gpu-system-execution.md)                  | Accepted                        | GPU system execution and transfer boundaries                             |
| [0003](decisions/0003-grid-stride-entity-iteration.md)          | Accepted                        | CPU/GPU grid-stride entity iteration                                     |
| [0004](decisions/0004-scoped-selection-errors.md)               | Accepted                        | Error propagation across scoped selection mutation and execution         |
| [0005](decisions/0005-filtered-spatial-row-reordering.md)       | Accepted                        | Filtered spatial clustering by periodic row reordering (not implemented) |
| [0006](decisions/0006-partitioned-spatial-archetype-storage.md) | Proposed                       | Cluster-local partitions beneath logical archetypes                      |
| [0007](decisions/0007-special-cluster-component.md)             | Rejected                        | Proposed special built-in `Cluster` component for placement              |
| [0008](decisions/0008-dirty-entity-spatial-classification.md)   | Proposed                       | Deferred classification of dirty entities instead of full scans (unplanned) |

## Recording a change

1. Search this index and the requirements for an existing decision. Check the
   implementation and tests before stating a behavior as implemented.
2. Add a numbered Markdown file under `decisions/` for a consequential choice:
   public API or compatibility, ownership/lifetime, data layout, safety,
   execution semantics, or a measured performance tradeoff. Use the next
   available four-digit number and a descriptive slug. For a minor clarification,
   update the existing record and explain the change in the commit.
3. Put decision metadata in YAML front matter using the schema below. Record
   **Context**, **Decision**, **Rationale**, **Consequences**, and links to requirements,
   tests, and implementation evidence. A short record is preferable to an
   untested claim. Proposed behavior must be clearly marked as proposed.
   Rejected records describe the proposal and why it was not adopted; they do
   not establish accepted behavior.
4. Once a decision is accepted, update this index, the affected requirements,
   implementation/tests, and public guides as appropriate. If an accepted
   decision changes, add a new record and set the old record's `status` to
   `superseded by NNNN`, replacing `NNNN` with the new decision's four-digit ID;
   retain its history and link to the replacement in the body or index.
5. Put unfinished tasks in the [roadmap](../roadmap.md). Keep detailed
   implementation evidence in tests, benchmarks, or change history and link it
   from a decision when useful; it is not the sole statement of the contract.

## Metadata schema

Each decision starts with YAML front matter delimited by `---`. Keep lifecycle
and planning metadata here rather than in a prose `Status:` paragraph. The index
is a human-readable summary and must agree with the front matter.

| Attribute       | Required        | Meaning                                                                                                                           |
| --------------- | --------------- | --------------------------------------------------------------------------------------------------------------------------------- |
| `id`            | Yes             | Quoted four-digit string matching the filename, such as `"0005"`. Quoting preserves leading zeros.                                |
| `title`         | Yes             | Decision title without the number; matches the document heading.                                                                  |
| `status`        | Yes             | `proposed`, `accepted`, `rejected`, `deprecated`, or `superseded by NNNN`. See the lifecycle meanings below. |
| `status_notes`  | No              | Qualifications such as experimental scope, implementation gaps, or validation evidence. Use a YAML block scalar for longer notes. |
| `planning`      | No              | `unplanned` when explicitly recorded as such. Omission makes no planning claim; use the roadmap for actual priorities and tasks.  |

- `proposed`: an alternative under consideration that has not been accepted or
  rejected. This includes undecided and unplanned alternatives.
- `accepted`: an adopted design, whether or not implementation is complete.
- `rejected`: a proposal explicitly declined.
- `deprecated`: a formerly accepted design that should no longer be used, with
  no accepted replacement recorded.
- `superseded by NNNN`: a formerly accepted design replaced by the referenced
  decision. Retain the old record as history.

Acceptance does not imply implementation. Preserve any existing implementation
or validation qualifications in `status_notes`; keep supporting evidence and
links in the body. Do not invent dates or planning commitments when migrating
an existing record.

New records can start with this outline:

```markdown
---
id: "NNNN"
title: "Short title"
status: proposed | accepted | rejected | deprecated | superseded by NNNN
---

# Decision NNNN: Short title

## Context

What problem or constraint requires a choice?

## Decision

What behavior or design is chosen?

## Rationale

Why this choice? Which relevant alternatives were considered?

## Consequences

What changes for users, implementers, performance, or compatibility?

## Evidence

Link to requirements, tests, measurements, and implementation plans.
```

For agent-specific workflow requirements, see [AGENTS.md](../../AGENTS.md).
