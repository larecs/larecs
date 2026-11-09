+++
type = "docs"
title = "Build documentation and figures"
weight = 4
+++

Run the publishing checks after changing a page, example, API contract, or
figure. Work from the repository root with the [locked setup](../setup).
The pipeline retains Modo; `mojo doc` supplies declarations, Modo extracts
examples and generates Markdown, and Hugo renders the site.

## Prepare the generation environment

Install the root and documentation environments, then the pinned Chromium build:

```sh
pixi install --locked
pixi install --locked --manifest-path scripts/pixi.toml
pixi run --manifest-path scripts/pixi.toml playwright install chromium
```

Generation supports Linux x86-64 and macOS Apple Silicon. `pixi.lock` pins
Mojo, MAX, and tracing dependencies; `scripts/pixi.lock` pins Python, Modo,
Hugo, Typst, Playwright, and the native macOS Go toolchain. Linux CI uses
Ubuntu 24.04, supported by the pinned Playwright release, and installs Chromium's
system libraries with `playwright install --with-deps chromium`.
On Apple Silicon, the wrapper builds the installed Modo release natively and
caches it under `scripts/.pixi/`; Linux uses its bundled executable.

## Build and verify

Run the publishing command before committing a documentation change:

```sh
pixi run verify-docs
```

The command performs these checks:

1. Clear generated Markdown and tests, regenerate compiler JSON, and run Modo
   with strict coverage and cross-reference checks.
2. Compare the source-derived doctest inventory with every extracted file.
   Compile and execute all extracted tests, all particle stages, and every
   program referenced by an `example` shortcode. There is no exclusion list.
3. Verify backend, resource/type-list, and spatial-registration rejection
   diagnostics with the existing compiler-contract checks. Their valid
   controls and the checked spatial stage must still compile.
4. Re-export every non-helper figure to a temporary directory and reject
   differences from the committed SVGs.
5. Build Hugo into an empty destination. Check every symbol/source target,
   root export, ordinary site link, repository evidence path, image, anchor,
   legacy redirect, and indexed search destination.
6. Exercise failure fixtures and a second deployment prefix. Chromium checks
   search navigation, retained redirect fragments, mobile navigation,
   360/768/1440-pixel layouts, expanded long declarations, and SVG canvases in
   both themes. Requests are served from generated files through browser
   interception; no server or live website is required.
7. Delete generated outputs and regenerate compiler JSON, Markdown, tests,
   metadata, and HTML. Require byte-identical files at the same revision and
   base URL. Programs execute once; the second extraction must match the
   files that executed.

`pixi run build-docs` runs steps 1–5 for a shorter edit cycle. Use
`pixi run --manifest-path scripts/pixi.toml test-docs` to rerun integration
fixtures after a build. The published files are in `docs/site/public/`.
Generated JSON, Markdown, tests, and HTML are disposable outputs; commit the
source pages, templates, programs, figure sources, and SVG exports.

The example log and `output/docs/examples.json` record actual device execution
separately from hardware skips. A successful compilation or host assertion is
not device coverage. Set `DOCS_REQUIRE_DEVICE=1` before either build command
on an accelerator machine to reject skips. CI can publish host-checked docs
without claiming accelerator execution. Browser screenshots and layout evidence
are in `output/docs/browser/`; inspect labels and captions there when a figure
or stylesheet changes. Automated checks cannot judge an explanation's clarity.

## Keep warnings fatal

Strict checks now apply to the complete generated tree. Missing alias/field
descriptions and malformed cross-references were repaired before enabling
Modo's `strict: true`. Declarations are URL-encoded between Modo and Hugo so
compiler-generated backticks cannot become false cross-references; the exact
compiler declaration remains available. The wrapper rejects Modo errors,
documentation warnings, and hook failures even when the packaged Linux launcher
returns zero. Hugo also runs with `--panicOnWarning`; the wrapper rejects its
template warnings.

All eight historical doctest exclusions are retired:

| Former label or source | Checked replacement or retirement |
| --- | --- |
| `HostStorage_add_entity_comps` | `HostStorage_add_entity` asserts individual creation. |
| `HostStorage_add_query_comps` | `HostStorage_add_components` checks filtered batch addition. |
| `HostStorage_remove_query_comps` | `HostStorage_remove_components` checks filtered batch removal. |
| `HostStorage_apply` | The commented historical example is no longer generated; current mutation uses the checked structural-change guide. |
| `Query_query_init` | Removed `Query` API; the queries/iteration doctest checks the current locked range. |
| `Query_query_without` | Removed `Query` API; the same checked guide covers exclusion filters. |
| `larecs_readme` | The shared particle program replaces the duplicated introduction example. |
| `Scheduler_scheduler` | The scheduler doctest now has a complete `main` and executes. |

A partially missing extraction fails as well as an empty directory. New
warnings must be fixed in the source or renderer; do not add a warning baseline
or omit a program to make the build pass.

## Add a checked excerpt

Keep a complete program with result assertions under `examples/particles/`.
Mark one coherent excerpt with `# region NAME` and `# endregion NAME`, then
include it and offer the full program:

```text
{{</* example file="particles/movement.mojo" region="kernel" */>}}
{{</* example file="particles/movement.mojo" full=true */>}}
```

The runner includes all particle programs and automatically includes referenced
programs elsewhere under `examples/`. Missing files, missing/empty/unbalanced
regions, unchecked inline Mojo fences, and missing entry points fail. Keep
required types, filters, kernels, and systems visible before explaining them.
Short standalone inline examples may use Modo's labelled doctest blocks;
`global=true` requires a complete `def main() raises:`. Hide imports only.

## Export figures and inspect the site

Edit the self-contained Typst/CeTZ sources, then update their exports:

```sh
pixi run figures
pixi run verify-docs
```

The figure build pins CeTZ `0.5.2`, uses `--ignore-system-fonts` with committed
Inter fonts, and exports every non-helper `docs/figures/*.typ`. Commit each
source and `docs/site/static/images/<name>.svg` together. Keep its caption,
alt text, and interpretation aligned. SVGs retain a light canvas in both
themes and scroll within the reading column on narrow screens. The
{{< repo "docs/figures/README.md" "figure catalog" >}} records provenance.

Use `pixi run serve-docs` after a build, or `pixi run watch-docs` while editing.
The watch loop supports iteration; `verify-docs` is the publishing gate.
Repository PR previews use
`https://larecs.github.io/larecs/pr-preview/pr-<number>/` through
{{< repo ".github/workflows/publish.yml" "the publishing workflow" >}}.

## Keep links and incoming URLs working

Use `api` for symbols, built-site paths for pages, and `repo` for repository
records outside `docs/src`. Repository/source/example links use the checkout's
HEAD revision; publish a committed checkout. Keep the initializer's `Exports:`
list aligned with imports. Inherited or compiler-synthesized members link to
their owning source declaration.

Guide compatibility routes and heading IDs are checked against
{{< repo "scripts/docs_legacy_urls.json" "the incoming-URL fixture" >}}.
Generated API aliases also retain method and overload fragments. On a
case-sensitive host, `System/` redirects independently of the `system/` module.
On a case-insensitive filesystem, the module landing page handles the legacy
capitalized URL without overwriting its own content. Keep these checks when
changing paths; a redirect must preserve both the base URL and incoming hash.
