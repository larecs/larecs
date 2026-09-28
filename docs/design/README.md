# Larecs design record

This directory is the source of truth for **accepted ECS requirements and design
decisions**. It explains why an API or invariant exists. The public
[`docs/src/guide/`](../src/guide/) teaches users how to use the library;
the [roadmap](../roadmap.md) tracks unfinished work by priority, and the
[changelog](../../changelog.md) records completed release history.

Start with [requirements](requirements.md) for the current contract and
[architecture](architecture.md) for the component map. Read the relevant
decision record before changing an established behavior:

| Decision | Status | Subject |
| --- | --- | --- |
| [0001](decisions/0001-locked-entity-selections.md) | Accepted | Locked entity selections and exact-range execution |
| [0002](decisions/0002-gpu-system-execution.md) | Accepted | GPU system execution and transfer boundaries |
| [0003](decisions/0003-grid-stride-entity-iteration.md) | Accepted | CPU/GPU grid-stride entity iteration |
| [0004](decisions/0004-gpu-dictionary-resource-views.md) | Proposed | GPU dictionary resource views and transfer ownership |

## Recording a change

1. Search this index and the requirements for an existing decision. Check the
   implementation and tests before stating a behavior as implemented.
2. Add a numbered Markdown file under `decisions/` for a consequential choice:
   public API or compatibility, ownership/lifetime, data layout, safety,
   execution semantics, or a measured performance tradeoff. Use the next
   available four-digit number and a descriptive slug. For a minor clarification,
   update the existing record and explain the change in the commit.
3. Record **Status** (`Proposed`, `Accepted`, or `Superseded`), **Context**,
   **Decision**, **Rationale**, **Consequences**, and links to requirements,
   tests, and implementation evidence. A short record is preferable to an
   untested claim. Proposed behavior must be clearly marked as proposed.
4. Once a decision is accepted, update this index, the affected requirements,
   implementation/tests, and public guides as appropriate. If an accepted
   decision changes, add a new record and mark the old one `Superseded by
   [NNNN](...)`; retain its history.
5. Put unfinished tasks in the [roadmap](../roadmap.md). Keep detailed
   implementation evidence in tests, benchmarks, or change history and link it
   from a decision when useful; it is not the sole statement of the contract.

New records can start with this outline:

```markdown
# Decision NNNN: Short title

Status: Proposed

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
