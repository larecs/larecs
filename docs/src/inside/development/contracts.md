+++
type = "docs"
title = "Change an ECS contract"
weight = 3
+++

Use this workflow when a change affects ownership, storage, query membership,
execution, safety, compatibility, or measured costs. It follows the existing
{{< repo "AGENTS.md" "repository guidelines" >}} and
{{< repo "docs/design/README.md#recording-a-change" "ADR workflow" >}}.

1. Locate the current requirement and relevant decisions in the
   [design map](../design). Check status and supersession before treating a
   decision as current. Verify behavior in `src/larecs` and focused tests;
   acceptance alone does not prove implementation.
2. For a consequential choice, add the next numbered file in
   `docs/design/decisions/` using the index's metadata schema and Context,
   Decision, Rationale, Consequences, and Evidence sections. Mark unaccepted
   ideas `proposed`. To replace an accepted choice, retain the old record,
   mark it superseded, and update the index and requirements.
3. Update implementation and representative correctness/compile-contract tests
   together. For row movement, preserve typed lifecycles, live identities,
   location repair, bounded membership, and invalidation. For execution,
   check fallback, empty matches, cleanup, binding lifetime, and unsupported
   targets. Use [architecture](../../architecture) to trace affected mechanisms.
4. Add or update representative benchmarks for changes to storage, queries,
   classification, movement, or execution costs. Follow the
   [methodology](../benchmarks) and [regression operation](../regression);
   a passing broad threshold does not prove zero overhead.
5. Update visible application consequences in guides, exact contracts in the
   reference/docstrings, and changed mechanisms in architecture. Extract
   runnable listings from checked sources, regenerate affected figures, and
   run the [documentation build](../documentation).

Keep unfinished tasks and priorities in {{< repo "docs/roadmap.md" "the roadmap" >}},
and completed release history in {{< repo "changelog.md" "the changelog" >}}.
Research notes and thesis alternatives remain evidence with their original
status; they do not create a second requirements or documentation-policy system.
The canonical {{< repo "docs/development.md#coding-standards" "coding standards" >}}
also govern listings and API docstrings.
