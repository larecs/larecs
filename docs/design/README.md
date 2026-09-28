# Larecs design record

This directory is the source of truth for **accepted ECS requirements and design
decisions**. It explains why an API or invariant exists. The public
[`docs/src/guide/`](../src/guide/) teaches users how to use the library;
release checklists and implementation plans track work and validation.

Start with [requirements](requirements.md) for the current contract and
[architecture](architecture.md) for the component map. Read the relevant
decision record before changing an established behavior:

| Decision | Status | Subject |
| --- | --- | --- |
| [0001](decisions/0001-locked-entity-selections.md) | Accepted | Locked entity selections and exact-range execution |

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
5. Put task lists, commit sequences, benchmark runs, and release status in
   implementation plans or release files. Link them from a decision when they
   provide evidence, but do not use them as the sole statement of the contract.

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
