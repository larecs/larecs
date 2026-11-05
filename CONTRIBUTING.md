# Contributing to Larecs🌲

## Set up

Install [Pixi](https://pixi.sh), clone the repository, and run the tests:

```sh
pixi run tests test
```

Pixi installs the pinned Mojo, MAX, and Tracy versions. Run a single test file
with `pixi run tests test/<filename>.mojo`, and format changes with
`pixi run mojo format src test benchmark`. The
[development reference](docs/development.md) holds the coding standards and
toolchain workarounds.

## Change behavior

Read the [design record](docs/design/README.md) before changing ECS behavior,
ownership, storage, queries, or execution. It holds the requirements, the
architecture overview, and the accepted decisions, and explains how to propose
or supersede one. Unfinished work is tracked in the [roadmap](docs/roadmap.md);
completed changes go into the [changelog](changelog.md).

Performance-relevant changes need representative benchmarks; the
[benchmark guide](docs/src/guide/benchmarks.md) describes the cases and the
measurement method.

## Write documentation

Follow the documentation conventions in
[`.agents/skills/larecs-docs/SKILL.md`](.agents/skills/larecs-docs/SKILL.md):
page kinds and navigation, the particle running example, voice, compiled
doctest examples, API links, figures, and docstrings. Build the site and its doctests with
`pixi run build-docs`.

## Commit and review

Use [Conventional Commits](https://www.conventionalcommits.org/)
(`type(scope): description`) with a body explaining what changed and why.
Keep each commit focused and the tests passing. Automated contributors also
follow [AGENTS.md](AGENTS.md).
