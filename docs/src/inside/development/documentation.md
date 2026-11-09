+++
type = "docs"
title = "Build documentation and figures"
weight = 4
+++

Run the complete pipeline after changing a page, example, API contract, or
figure. Work from the repository root with the [locked setup](../setup).
We retain Modo and the existing documentation conventions.

## Generate and check the site

Build the site and run the reference integration suite:

```sh
pixi run build-docs
pixi run --manifest-path scripts/pixi.toml test-api-reference
```

The first command clears generated pages/tests, generates compiler JSON with
`mojo doc`, runs Modo, compiles and runs every extracted doctest and particle
program, creates API metadata, builds Hugo, and checks reference symbol/link
targets. Output is in `docs/site/public/`. The integration suite checks root
aliases, module-only symbols, export drift, constraints, exact declarations,
redirects, and revision-pinned source links. A missing extracted-test directory
or empty doctest inventory fails rather than reporting success.

On Apple Silicon, `scripts/docs.py` builds the installed Modo release natively
with the scripts environment's Go toolchain and caches it under `scripts/.pixi/`.
Linux uses the bundled executable. Existing Modo missing-description and
cross-reference warnings stay visible; this pipeline does not enable blanket
strict mode. A Modo script-error line still fails the wrapper even when Modo
returns zero.

## Add a checked excerpt

Keep a complete runnable program in `examples/particles/`, with result
assertions. Delimit a coherent excerpt with `# region NAME` and
`# endregion NAME`, then use the existing shortcode:

```text
{{</* example file="particles/movement.mojo" region="kernel" */>}}
{{</* example file="particles/movement.mojo" full=true */>}}
```

The first form displays the exact checked region; the second offers the whole
program. Missing files or regions fail Hugo. Show required types, filters,
kernel, and system before explaining them; do not hide definitions needed to
read a listing. The runner already includes every particle program. Add any
new example directory to `scripts/run_doctests.sh` so it cannot escape execution.
Short inline Modo doctests need a complete `def main() raises:` when global;
do not mix global and wrapped non-global blocks under one label.

## Export reproducible figures

Edit the self-contained sources in `docs/figures/`, then export all figures:

```sh
pixi run figures
```

`scripts/build_figures.py` compiles every non-helper `*.typ` source; filenames
starting with `_` are helpers. Typst uses `--ignore-system-fonts` and the
committed Inter fonts. Sources pin CeTZ `0.5.2`. Outputs go to
`docs/site/static/images/<name>.svg`. Commit source and SVG together, compare
repeat-export hashes, inspect rendered labels, and put explanatory prose,
descriptive alt text, and an italic caption beside each figure. The
{{< repo "docs/figures/README.md" "figure catalog" >}} records thesis provenance
and changes to historical layouts. Export runs separately from `build-docs`.

## Verify paths and generated declarations

Use the `api` shortcode for API symbols and built-site paths for published
pages. Unknown API names fail the build. Keep the initializer's `Exports:` list
aligned with imports; a module-only symbol does not become a root export by
appearing in the generated module tree.

Use the `repo` shortcode for repository evidence outside `docs/src`, for
example `repo "docs/design/README.md" "Design index"`. It pins the link to
the same HEAD revision as API source links. Build a committed checkout for
publication. The [design map](../design) deliberately links the canonical
repository records rather than duplicating their metadata into generated pages.

Check changed page links, generated heading IDs, image targets, and figure
labels in `docs/site/public/`. Asset links such as `/images/architecture.svg`
must remain under the configured base URL, including PR previews. To inspect
locally, use `pixi run serve-docs` after a build or `pixi run watch-docs` while
editing. Repository PR previews use
`https://larecs.github.io/larecs/pr-preview/pr-<number>/`; generation and
deployment remain in {{< repo ".github/workflows/publish.yml" "the existing workflow" >}}.
