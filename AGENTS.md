# Agent Guidelines for Larecs

Larecs is a performance-critical Entity Component System library written in Mojo.

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
