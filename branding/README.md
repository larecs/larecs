# larecs branding

Tooling for the larecs logo: a generator that builds every logo asset from
geometric primitives, an interactive playground for tuning the logo, and the
exploration concepts that led to it.

## Regenerating

All SVGs are generated. Edit the geometry in `generate_logos.py` and regenerate:

```sh
uv run branding/generate_logos.py            # SVGs, PNGs and favicon.ico
uv run branding/generate_logos.py --no-png   # SVGs only
```

PNGs need `rsvg-convert` (librsvg) and `favicon.ico` needs `magick`
(ImageMagick); the generator warns when either is missing and skips those
outputs, leaving any tracked copies stale.

The wordmark is outlined from Inter (variable, `wght` 500). Pass `--font PATH` or
set `LARECS_WORDMARK_FONT` if Inter is not installed in `~/Library/Fonts`.

The generator also writes the production assets for the chosen logo (`V12`) to
`final/`. Open `previews/index.html` to compare all concepts. Concepts,
variants, avatars, wordmarks and previews are regenerated on demand and not
tracked.

## Concepts

| ID | Name | Idea |
|---|---|---|
| L01 | Corner | Reconstruction of 6.1: isometric wall folded into a floor; one entity on its own cell |
| L02 | Slit hexagon | Solid isometric emblem; the L is the slit between the occupied corner and a free cell |
| L03 | Cells | Five cells form an L on an implied 3 × 3 grid; an entity sits in the crook |
| L04 | Extruded | Shallow isometric extrusion of a flat L, three tones |
| L05 | Axes | The three isometric axes from one origin; up + forward form the L, depth ends in a node |
| L06 | Segmented corner | L01 rebuilt from five identical isometric cells |
| L07 | Cut L + spire | Flat L with 30°/60° cuts and an equilateral spire in the crook |
| L08 | Quadtree | Recursive subdivision: each square keeps an L and subdivides its fourth quadrant |
| L09 | Corner + node | L01 reduced to wall, floor and one floating entity |
| L10 | Folded ribbon | One strip folded up the wall, across the floor and into a step |
| T01 | Corner + conifer | L01 with the entity drawn as a conifer, knocked out of the planes |
| T02 | Spruce stem | The L is the tree: one stem from tip to ground line, tiers either side |
| T03 | Half spruce | Stem and isometric branches form one side of a spruce; stem + lowest branch are the L |
| T03R | Half spruce, rounded | T03 with a rounded bend; outer and inner radius set separately |
| T04 | Canopy L | Flat L whose stem ends in a round crown |
| T05 | Quadtree forest | L08 whose final leaf is a conifer |
| T06 | Seam spruce | Solid tiered spruce split by an L-shaped seam into lit and shaded parts |
| T07 | Grove corner | L01 corner holding two conifers of different heights |
| B01 | Iso branch | Minimal Branch (5.1) on isometric angles, asymmetric |
| G01 | Sparse grid | Grid Forest (4.4) as a 2 × 2 isometric grid with two entities |

## Layout

| Path | Contents |
|---|---|
| `concepts/<family>/<ID>.svg` | Master icon, full colour for dark backgrounds, transparent |
| `variants/{dark,light,monochrome}/<ID>-<treatment>.svg` | Colour, ivory, forest, black, white, muted green and alternative palettes, transparent |
| `avatars/<ID>-{forest,deep,ivory}.svg` | Full-bleed backgrounds; content fits a circular crop |
| `wordmarks/<ID>-{dark,light}.svg` | Icon + outlined wordmark; `wordmarks/editable/` keeps live text |
| `previews/` | Comparison boards, size test, HTML gallery, rendered PNGs |

## Colour roles

Each icon uses up to four roles, emitted as `class="r-a"` … `class="r-d"` with explicit fills:
`a` primary form, `b` secondary face, `c` accent, `d` secondary accent. Monochrome
treatments map all roles to one colour; gaps in the geometry keep the forms separate.
Colours live in `palette.json`.

## Playground

`previews/playground.html` is an interactive editor. It opens on V12, the
current logo: a T03R variation built from one generalised shape whose corners,
cuts, slant angle and branch layout are all adjustable. Open it with `?all` to
also show the other variations (V01–V13) and the archived exploration concepts.
"Copy share link" puts the current settings into the URL fragment
(`#preset=…`); opening that link restores them.

The docs workflow (`.github/workflows/publish.yml`) publishes the playground
with the docs site at <https://larecs.github.io/larecs/branding/> on every push
to `main`. The deployed page shows only V12 and hides the local gallery and
archive links.

"Propose on the logo PR" copies a comment with a share link to the deployed
playground and opens the logo pull request; paste it there. On pull requests
labelled `logo`, the `render-logo-presets` workflow answers such comments with
a rendering of the variation (`render_preset.py`), stored on the orphan
`branding-renders` branch.

It ports every concept's geometry to JavaScript with sliders for thicknesses,
gaps and proportions, plus colour pickers per role, presets, size and avatar
previews, and SVG export. It runs from the local file. `previews/vendor/` holds the polygon-clipping
library (MIT) that it uses for unions and seams. Exported SVGs use masks for
gaps; production assets should be regenerated from `generate_logos.py`
once the parameters are chosen. Use "Copy settings JSON" to hand them over.
