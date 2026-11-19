# Changelog fragments

Each feature branch records its user-visible changes in one fragment,
`changelog.d/<feature>.md`, instead of editing `changelog.md`. Fragments travel
with their branch into `nightly` and `main`, and the release collects them into
a new version section of `changelog.md`.

A fragment groups entries under `### Breaking changes`, `### Added`,
`### Changed`, `### Fixed`, or `### Removed`. Each entry describes the feature
as it currently behaves and ends with links to every PR that shaped it:

```markdown
### Added

- Add opt-in threaded host execution. ([#187](https://github.com/larecs/larecs/pull/187), [#189](https://github.com/larecs/larecs/pull/189))
```

A follow-up PR on the same feature rewrites the entry and appends its own link.
`python3 scripts/changelog.py preview` shows the collected unreleased changes.
