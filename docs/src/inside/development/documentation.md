+++
type = "docs"
title = "Build documentation and figures"
weight = 4
+++

Run the publishing checks after changing a page, example, API contract, or
figure. Work from the repository root with the [locked setup](../setup).
`mojo doc` supplies declarations; `scripts/render_docs.py` generates API and
handwritten pages for Astro and Starlight. Pagefind indexes the rendered site.

## Prepare the environment

```sh
pixi install --locked
pixi install --locked --manifest-path scripts/pixi.toml
pixi run --manifest-path scripts/pixi.toml playwright install chromium
```

The root lock pins Mojo, MAX, and tracing dependencies. `scripts/pixi.lock`
pins Python, Node, Typst, and Playwright for Linux x86-64 and macOS Apple
Silicon; `docs/site/package-lock.json` pins Astro and Starlight. The build runs
`npm ci`. Linux CI also installs Chromium's libraries with
`playwright install --with-deps chromium`.

## Build and verify

```sh
pixi run verify-docs
```

Both `build-docs` and `verify-docs` regenerate compiler JSON, API metadata,
Markdown, and executable doctests. They compile and execute every extracted
doctest, every particle program, and every program referenced by an `example`
directive before rendering the site. Missing programs, regions, entry points,
or extracted tests fail the build. An assertion or execution failure prevents
publishing. There is no exclusion list.

Both commands also run backend, resource, and spatial rejection checks, compare
figure exports, and validate symbol targets, source lines, site links, images,
anchors, and legacy URLs. `verify-docs` additionally runs regression fixtures,
Chromium layout, search, and redirect checks, then requires byte-identical clean
regeneration at the same revision and deployment URL.

Generated files live under `docs/site/src/content/docs/`, `docs/site/data/`,
`docs/test/`, and `docs/site/public/`. They are disposable. Commit authored
pages under `docs/src/`, runnable programs, renderer sources, lock files,
and figure sources with their SVGs.

`output/docs/examples.json` records actual device execution separately from
hardware skips. Set `DOCS_REQUIRE_DEVICE=1` on an accelerator machine to reject
skips. A successful compilation alone is not device coverage.

## Add a checked excerpt

Keep the complete runnable program and its assertions under `examples/particles/`.
Mark excerpts with `# region NAME` and `# endregion NAME`. Include the code from
that file rather than copying it:

```text
{{</* example file="particles/movement.mojo" region="kernel" */>}}
{{</* example file="particles/movement.mojo" full=true */>}}
```

Excerpts retain relative indentation and come from the exact file executed by
the publishing gate. The full form links to the program at the checkout's
revision. Other example directories are included when a page references them.
Short inline Mojo examples require a `doctest="label"` fence; `global=true`
blocks supply a complete `def main() raises:`. Otherwise the extractor wraps
the block in `main`. Hide only imports with `hide=true`.

Show every type, filter, kernel, and system before explaining it. Use the
public `ComponentType` and `ResourceType` constraints in examples. Explain
an ECS contract using *entities*; reserve *particles* for facts about the
running simulation. Link Mojo language concepts to the Mojo manual.

## Export figures

```sh
pixi run figures
pixi run verify-docs
```

The build pins CeTZ and committed Inter fonts. Commit each non-helper Typst
source with its `docs/site/static/images/<name>.svg` export. Keep captions and
alt text aligned with the figure. The
{{< repo "docs/figures/README.md" "figure catalog" >}} records provenance.

## Preview and deploy

`pixi run serve-docs` generates the source pages and starts Astro's development
server. `pixi run watch-docs` uses the same server; rerun it after changing
compiler declarations or example sources. Use `verify-docs` before publishing.

`DOCS_BASE_URL` selects the deployment prefix. Development docs live at
`https://larecs.github.io/larecs/dev/`; PR previews use
`https://larecs.github.io/larecs/pr-preview/pr-<number>/`. A release can build
at `/larecs/v<version>/` without overwriting development docs. The header
identifies the development version; no selector advertises unpublished versions.
The {{< repo ".github/workflows/publish.yml" "publishing workflow" >}} deploys
only after the execution and rendering gates pass.

Use `api` directives for symbols and `repo` directives for records outside the
site. Source links are pinned to the checkout revision. Preserve incoming
routes and fragments in
{{< repo "scripts/docs_legacy_urls.json" "the compatibility fixture" >}}.
Case-only API redirects keep module pages intact on case-insensitive filesystems.
