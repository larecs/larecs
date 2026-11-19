# Agent Guidelines for Larecs

Larecs is a performance-critical Entity Component System library written in Mojo.

## Issues and Branches

- Before starting a task, find its issue: search open issues with
  `gh issue list --state open --search "<keywords>"` and check the sub-issues of
  related parent issues. Tell the developer which issue you are working on. If
  none fits, ask whether to create one (use the `issue-description` skill), and
  start without an issue only when the developer says so.
- Work on a feature branch linked to the issue. Create it with
  `gh issue develop <N> --name <branch> --base <base> --checkout`, where `<base>`
  is `main` or, when the work needs an unpromoted feature, that feature's
  branch. Never base work on `nightly` and never merge `nightly` into a
  feature branch; merging `main` into it is fine. When an issue exists, create
  the work branch only this way, not with `git switch -c`, `git checkout -b`,
  or `git branch`.
- Record user-visible changes in one fragment per feature,
  `changelog.d/<feature>.md`, never in `changelog.md`. Group entries under
  `### Breaking changes`, `### Added`, `### Changed`, `### Fixed`, or
  `### Removed`, describe current behavior, and end each entry with the links
  of every PR that shaped it, such as
  `([#187](https://github.com/larecs/larecs/pull/187))`. A follow-up PR
  rewrites the entry and appends its link. PRs with no user-visible change get
  the `no-changelog` label instead.
- Open PRs from the feature branch into `nightly` and merge them with a merge
  commit once checks pass. Open a PR into `main` only when the developer asks
  to promote a feature or prepare a release; it comes from the same feature
  branch, so promoted commits are identical on both branches. When the
  developer names features to promote by their changelog entries, find the
  fragments and their branches, promote stacked branches bottom-up, and
  consolidate refinements on the branch before opening the PR.
- Rebuild `nightly` only when the developer asks, with
  `scripts/rebuild_nightly.sh`; [CONTRIBUTING.md](CONTRIBUTING.md) and
  `docs/src/guide/development_workflow.md` describe the full lifecycle.
- If tooling already started you on its own branch, such as a managed worktree,
  create the linked branch with `gh issue develop` without `--checkout`, then
  run `git fetch origin <branch>` and `git switch <branch>` before your first
  commit.
- Confirm the link with `gh issue develop --list <N>`. A branch links to one
  issue; when a PR resolves further issues, add their `Closes #N` lines and tell
  the developer which ones need a manual Development link, because GitHub only
  links closing keywords for PRs into `main`.

## Pull Request Descriptions

Use the `pr-description` skill to write or revise a description; `.github/pull_request_template.md` holds the skeleton.

- Title the PR with a concise summary of the work in sentence case, such as "Add opt-in threaded host execution". Do not use Conventional Commits form for PR titles.
- Open with the problem or motivation in one or two sentences, then the change.
- Under `## Features`, list each implemented feature as a bullet with a short description of what callers observe: opt-in flags, newly rejected inputs, preserved invariants. Add implementation details only where reviewers need them to understand the behavior.
- Under `## API changes`, list each changed user-facing API with a short reason.
- Delete template sections that would be empty. When a PR closes several issues, a table mapping issues to changes may replace the feature list.
- For breaking changes, add a `## Breaking change` section that states what callers must change and links the design decision records that document it.
- End with one `Closes #N` line per resolved issue.
- Never include validation: test runs or counts, hardware, sanitizer or doctest results, CI or review-bot status, or what remains untested.
- Never include benchmark results unless the developer explicitly asks for them.
- Never include PR metadata: stack or base relationships, branch names, commit hashes or counts, review ranges or walkthroughs, or narratives about what other PRs supply. Use the hosting platform's metadata fields or stack tooling.
- Never include commit or process history, follow-up or roadmap work, or AI attribution.
- The Issue Writing rules on other projects and local filesystem paths apply to PR titles and bodies too.

## Design records

- Read [the design index](docs/design/README.md) and relevant
  [requirements](docs/design/requirements.md) and decisions before changing
  ECS behavior, ownership, storage, query, or execution semantics.
- Record consequential new choices as numbered files in `docs/design/decisions/`
  using the status, context, decision, rationale, consequences, and evidence
  convention in the index. Mark unaccepted ideas `Proposed`.
- When an accepted choice changes, add a superseding decision and update the
  index and requirements; retain the earlier record for history. Update code,
  tests, and user guides to match the accepted behavior.
- Track unfinished work in the single [roadmap](docs/roadmap.md), grouped by
  **Next release**, **Later**, or **Unscheduled**. Move items between priority
  buckets as needed; do not add per-version todo files. Put completed release
  history in the [changelog](changelog.md).
- Keep tasks separate from durable design records; link decisions and evidence.
  Do not mark a requirement implemented solely because it appears on the roadmap.

## Implementation and review

- Before writing or reviewing Mojo, read the [coding standards](docs/development.md#coding-standards)
  and use the `mojo-syntax` skill.
- When changing storage, queries, classification, row movement, or execution costs,
  add or update representative benchmarks. Read the
  [benchmark methodology](docs/src/guide/benchmarks.md#benchmark-methodology) and
  relevant workload sections before changing benchmarks or reporting performance.

## Issue Writing

- Keep issue titles, bodies, and comments focused on Larecs. Never mention other projects unless the developer explicitly requests it.
- Never include local filesystem paths in issues, including pasted logs or command output. Use repository links or symbol names to identify code.
- Manage prioritization and scheduling through issue metadata, such as milestone assignments and priority fields or labels. Keep priority levels, deferral status, and release scheduling out of issue titles, bodies, and comments.

## Known issues

- GPU test files must use `# SKIP_DEBUG`; read the
  [Metal compiler workaround](docs/development.md#metal-debug-info)
  when adding GPU tests or diagnosing Metal compilation failures.
- For macOS linking errors mentioning `arm64e.x1` or `libSystem.tbd`, read the
  [SDK workaround](docs/development.md#macos-sdk-linking).

## Common commands

- Run all tests: `pixi run tests test`
- Run one test: `pixi run tests test/<filename>.mojo`
- Format code: `pixi run mojo format src test benchmark`
- Generate API docs: `pixi run mojo doc -o docs/src/larecs.json src/larecs`
- Benchmark commands, baseline selection, and regression thresholds:
  [benchmark guide](docs/src/guide/benchmarks.md).
