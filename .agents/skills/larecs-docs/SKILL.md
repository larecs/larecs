---
name: larecs-docs
description: "Larecs documentation conventions for guide pages under docs/src, the README, API docstrings in src/larecs, figures, and docs navigation. Use with writing-docs when writing, restructuring, or reviewing any of them."
---

# Larecs docs

Apply the global `writing-docs` skill when it is installed; this skill adds
the Larecs specifics and stands alone without it. Use the `mojo-syntax` skill
for every Mojo snippet. The structure plan and known defects live in
`docs/documentation-review.md` (issue #220 and its sub-issues); check it
before adding or moving a page.

## Core rules

- Each page is one kind: tutorial, how-to guide, reference, or explanation.
  Move material of another kind to its own page and link it.
- How-to pages: task title, one paragraph on outcome and when to use it,
  minimal complete example, variations, failure behavior, next links.
- Show, then explain; the code the prose discusses is visible.
- Document what exists now. State each limit once, plainly, beside the
  feature. Make performance claims checkable or describe the cost model.
- Second person, present tense, active voice, short sentences; one term per
  concept.

## Navigation

| Section | Kind | Voice |
| --- | --- | --- |
| Start | Overview, install, first simulation (tutorial) | "you" |
| Guides | Task-oriented how-to pages | "you" |
| Reference | Curated contracts plus generated API pages | "you", or neutral |
| Inside Larecs | Architecture, design rationale, development, benchmarks | "we" |

Users read Start, Guides, and Reference without needing Inside Larecs; those
pages link inward for rationale. Never label a page or section by audience.
Inside Larecs explains accepted decisions from `docs/design/` and links to
them; it does not restate the decision records.

## Running example: particles

`examples/particles/` holds the particle simulation, one complete program per
stage; `movement.mojo` is the first stage, taught by
`docs/src/start/first_simulation.md`. Later pages reuse its types, field
names, and system names verbatim (`Position.x/y`, `Velocity.dx/dy`,
`Time.delta`, `move`, `Move`) and add one feature per stage, such as entity
creation and removal, configuration resources, threaded or device execution,
or spatial clustering. Other domains appear only where particles cannot
express the feature, and the page says why.

## Compiled examples

Every visible snippet compiles and runs.

- Tutorial and guide examples live in checked programs under `examples/`.
  Mark excerpts with `# region NAME` / `# endregion NAME` and show them with
  `{{< example file="particles/movement.mojo" region="kernel" >}}`; offer the
  whole program with `full=true`. A missing file or region fails the Hugo
  build. `scripts/run_doctests.sh` compiles and runs every program in
  `examples/particles/`; add new example directories there.
- Short standalone snippets may stay inline as Modo doctest blocks
  (`{doctest="<label>" global=true}` with a complete `def main() raises:`,
  because Modo's own wrapper is invalid Mojo). Use `hide=true` only for
  imports and entry-point lines.
- Show every type, filter, kernel, and system before the prose explains it.
- Assert the outcome the prose claims with `std.testing` (`assert_equal`,
  `assert_almost_equal`, `assert_raises`).
- API docstrings use the canonical public path (`world.storage.add_entity`,
  not `world.add_entity`). Show call forms as inline code and link the
  tutorial or guide for a complete program. Remove a file from
  `known_unsupported_doctests` in `scripts/run_doctests.sh` once its example
  is fixed.

Verify with `pixi run build-docs`: it runs `mojo doc`, Modo, the extracted
doctests and example programs, and Hugo, and works on Linux and Apple Silicon
(Modo is built natively there). Check the rendered HTML in
`docs/site/public/`; `pixi run serve-docs` serves the site locally. Pull
requests from repository branches deploy a preview to
`https://larecs.github.io/larecs/pr-preview/pr-<number>/`
(`.github/workflows/publish.yml`). Internal links must follow `baseURL`
(`relURL`, relative paths, or `/images/...` through the theme) so they stay
inside the preview.

## Pages, links, and figures

- Pages live in `docs/src/<section>/` with TOML front matter
  (`type = "docs"`, `title`, `weight`). Titles name the task.
- Link API symbols with `{{< api HostStorage.query query >}}` at first mention
  per page. Link other pages by their built-site path and check heading anchors
  against the generated IDs. Methods with overloads get `#name-0`, `#name-1`.
- Published pages cannot reach `docs/design/*.md` by relative path; link the
  Inside Larecs page or the GitHub file URL.
- Terms follow `GLOSSARY.md`; add new terms there in the same change.
- Figures are Typst/CeTZ sources in `docs/figures/` (adapted from the master
  thesis with current names such as physical store, partition, selection,
  kernel chunk). `pixi run figures` writes deterministic SVGs to
  `docs/site/static/images/`; reference them as `/images/<name>.svg`, with alt
  text describing what the figure shows and an italic caption naming what to
  notice. Commit source and SVG together.

## Contracts to check

Before stating behavior, confirm it in `src/larecs` and `test/`. These areas
drifted before: component and resource eligibility per execution target,
kernel invocation granularity (per physical store, selected range, or threaded
chunk), device transfers and copy reuse, synchronization bindings (standalone
primitives only), exports from the `larecs` root, and performance claims
(link `docs/src/guide/benchmarks.md` measurements with their environment).

## API docstrings

Follow the docstring template in
`docs/development.md#coding-standards`. The summary line and contract
render visibly; the readable declaration hides `mojo doc`'s `where` clauses
and keeps the exact one collapsed (`docs/templates/`,
`docs/site/layouts/shortcodes/declaration.html`). For a primary method, the
description covers common call forms, execution or invocation behavior,
access rules, empty or failure behavior, and how its overloads differ.

- Document `out` results under `Returns:`, not `Args:`.
- State raised errors with their conditions, reference invalidation after
  structural changes, and lock effects.
- Modo reads `[name]` as a cross reference, even inside inline code; write
  `KernelContext` rather than `KernelContext[...]` in prose. Cross references
  inside `Constraints:` are not resolved; use plain code there.
- Regenerate with `pixi run mojo doc -o docs/src/larecs.json src/larecs` and
  keep it free of warnings.
