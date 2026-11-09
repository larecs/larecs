# Documentation figures

Run `pixi run figures` from the repository root. The scripts environment pins
Typst through `scripts/pixi.lock`; sources import CeTZ 0.5.2 and the shared
`_style.typ`. The build compiles every non-helper `docs/figures/*.typ` with
`--ignore-system-fonts` and the committed Inter fonts, writing matching SVGs
under `docs/site/static/images/`. No source requires the thesis checkout.
Captions, alt text, and interpretation live beside each published figure.

These figures adapt visual mechanisms from the thesis's `figs.typ` and
`thesis.typ`, inspected for documentation work package #226. They use current
source and tests for contracts; the thesis is historical explanatory material.

| Export | Thesis source | Adaptation and published explanation |
| --- | --- | --- |
| `architecture.svg` | `larecs-architecture`, architecture section | Current SystemContext borrow, owned resource/device state, physical stores, and invocation views; [ownership](../src/inside/architecture/ownership.md). |
| `component-memory.svg` | `archetype-memory`, `aos-soa-memory` | Descriptor-owned typed allocations/lifecycles; complete component structs rather than scalar-field columns or a historical header ABI; [storage](../src/inside/architecture/storage.md). |
| `structural-transition.svg` | `archetype-add-component` | Retained-value move, added-value initialization, source swap-removal and both location repairs; canonical staging destination; [storage](../src/inside/architecture/storage.md). |
| `host-execution.svg` | `host-execution` | Physical-store ranges, `Move`/`move` particle names; [first simulation](../src/start/first_simulation.md). |
| `execution-mapping.svg` | `host-execution`, `threaded-host-execution`, `device-grid-stride` | Context-local ranges/chunks, dynamic claims and packed grid stride; [work mapping](../src/inside/architecture/execution.md). |
| `device-transfer.svg` | `device-memory`, component-transfer section | Selected-span packing/scatter, component access directions, untouched gaps; [transfers](../src/inside/architecture/transfers.md). |
| `device-copy-reuse.svg` | `device-copy-reuse` | Revision validity, unchanged-upload skipping and eager outputs; [transfers](../src/inside/architecture/transfers.md). |
| `spatial-placement.svg` | `spatial-ordering`, `spatial-grouping` | Default ordering versus one growable store per logical cluster; no historical fixed block cap; [spatial maintenance](../src/inside/architecture/spatial.md). |
| `spatial-maintenance.svg` | Spatial-proximity section, `spatial-ordering`, `spatial-grouping` | Dirty full identities, explicit boundary, callback failure before movement and commit; [spatial maintenance](../src/inside/architecture/spatial.md). |

Containment and arrows describe ownership or work flow, not stable object byte
offsets. Four-thread grids and four-slot capacities are illustrative. Historical
bounded-block timings stay labeled in the [partition reports](../src/inside/development/reports/partitions.md).
