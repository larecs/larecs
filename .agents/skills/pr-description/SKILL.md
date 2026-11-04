---
name: pr-description
description: Write or revise a pull request title and description. Use when opening a PR, editing an existing PR body, or checking whether PR descriptions follow the repository's rules.
---

# PR descriptions

If the repository's `AGENTS.md` (or `CLAUDE.md`) has PR description rules, or `.github/pull_request_template.md` exists, follow them; they win over this skill.

## Write

1. Read what the PR changes: `gh pr diff N` (or `git diff BASE...HEAD`), the linked issues, and any design decision records (ADRs) the diff adds or changes.
2. Write the opening: what was wrong or missing, then what the PR changes. One or two sentences each.
3. Under `## Features`, list each implemented feature as a bullet with a short description of what callers observe: opt-in flags, newly rejected inputs, preserved invariants. Add implementation details only where reviewers need them to understand the behavior. When the PR closes several issues, an `| Issues | Changes |` table may replace the list.
   Under `## API changes`, list each changed user-facing API in backticks with a short reason. Delete sections that would be empty.
4. If callers must change code, add `## Breaking change`: the old and new spelling or contract, and full GitHub links to the ADRs that document it (relative links do not resolve in PR bodies).
5. Add one `Closes #N` line per resolved issue.
6. Apply with `gh pr create --body-file FILE` or `gh pr edit N --body-file FILE`.

## Check before publishing

Remove anything that matches these. Keep benchmark results only when the developer explicitly asked for them.

- Validation: "Validation"/"Testing" headings, test commands, "passed", test or doctest counts, sanitizer runs, hardware used for testing, "compile-checked", "untested".
- Benchmarks: timings, speedups, memory figures, result tables.
- Metadata: "Stacked on", "based on", "review against", branch names, commit SHAs, commit counts, "To review, start with".
- Status: CI runs, Greptile/CodeRabbit/other bot results, approval or mergeability.
- History and future: "originally", renumbering, "follow-up", "remains on the roadmap", "not in this PR".
- Other projects, local filesystem paths, and AI attribution such as "Generated with Claude Code".

Typical length is two or three short paragraphs.

## Example

```markdown
Larecs execution and transfer APIs used CPU/GPU names for roles that may also apply to other accelerators. Rename the beta APIs to describe the host/device boundary.

## API changes

- `run[..., on_gpu=True]()` → `run[..., on_device=True]()`: the flag selects the device side of the host/device boundary, not a hardware type.
- `GPUComponentType` → `DeviceComponentType` and `GPUResourceType` → `DeviceResourceType`: same reason; transfer restrictions are unchanged.

## Breaking change

Rename the calls and types above; no compatibility aliases remain. See [decision 0015](https://github.com/larecs/larecs/blob/main/docs/design/decisions/0015-host-device-execution-terminology.md).
```
