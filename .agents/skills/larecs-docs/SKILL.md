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

The Start tutorial "Your first simulation" defines the canonical particle
simulation. Every later user page reuses its types, field names, and system
names verbatim and adds one feature (a resource, a write-only output, spawning
batches, threaded or device execution, spatial clustering). Read that page
before writing an example; when an example needs a new type, add it in the
style of the existing ones and keep it consistent across pages. Other domains
appear only where particles cannot express the feature, and the page says why.

## Compiled examples

Every visible snippet compiles and runs. Guide pages use Modo doctest blocks:

````markdown
```mojo {doctest="<page_label>" global=true hide=true}
from larecs import World, Filter
```

```mojo {doctest="<page_label>" global=true}
def main() raises:
    var world = World[Position, Velocity]()
```
````

- Blocks sharing a `doctest` label concatenate into one file; write a complete
  `def main() raises:` program because Modo's own wrapper is invalid Mojo.
- `hide=true` only for imports, entry point lines, and setup the page already
  showed in the same form. Types, filters, kernels, and systems that the prose
  explains are visible before they are used.
- Assert the outcome the prose claims with `std.testing` (`assert_equal`,
  `assert_raises`), so a behavior change fails the doctest.
- API docstring examples follow the same rule: complete program, canonical
  public path (`world.storage.add_entity`, not `world.add_entity`), `var` for
  new variables. Remove a file from `known_unsupported_doctests` in
  `scripts/run_doctests.sh` once its example is fixed.

Verify with `pixi run build-docs` (runs `mojo doc`, Modo, extracted doctests,
and Hugo). The Modo binary fails on Apple Silicon (`Bad CPU type`); verify
there by compiling the snippet as a standalone file with
`pixi run mojo run -I src <file>.mojo` and rely on the Linux CI build for the
extraction itself. Report which path you used.

## Pages and links

- Guide pages live in `docs/src/<section>/` with TOML front matter
  (`type = "docs"`, `title`, `weight`). Titles name the task.
- Link API symbols with `{{< api HostStorage.query query >}}` at first mention
  per page. Link other pages by their built-site path and check heading anchors
  against the generated IDs.
- Published pages cannot reach `docs/design/*.md` by relative path; link the
  Inside Larecs page or the GitHub file URL.
- Terms follow `GLOSSARY.md`; add new terms there in the same change.
- Figures from the master thesis are redrawn with current names (storage,
  physical store, partition, selection, kernel chunk); store sources next to
  the exported image under `docs/src/**/images/`.

## Contracts to check

Before stating behavior, confirm it in `src/larecs` and `test/`. These areas
drifted before: component and resource eligibility per execution target,
kernel invocation granularity (per physical store, selected range, or threaded
chunk), device transfers and copy reuse, synchronization bindings (standalone
primitives only), exports from the `larecs` root, and performance claims
(link `docs/src/guide/benchmarks.md` measurements with their environment).

## API docstrings

Follow the docstring template in `AGENTS.md`. Document `out` results under
`Returns:`, not `Args:`. State raised errors with their conditions, reference
invalidation after structural changes, and lock effects. Regenerate with
`pixi run mojo doc -o docs/src/larecs.json src/larecs` and keep it free of
warnings.
