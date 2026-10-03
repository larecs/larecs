+++
type = "docs"
title = "Benchmarks"
weight = 100
+++

The focused `entity_selection_benchmark.mojo` workload compares ordinary
full-world CPU execution with contiguous and disjoint 64-row selections in a
100,000-row world, a selected add/remove chain, and selected GPU execution when
an accelerator is available. On the Apple Metal development host used for the
1.0.0b2 work, one bounded run measured approximately 0.0253 ms for the 100k-row
CPU path, 0.0000664 ms for the contiguous selection, 0.000556 ms for 64 disjoint
single-row ranges, 0.00727 ms for the add/remove chain, and 0.379 ms for the GPU
selection. These are development measurements, not a cross-version historical
baseline; use the benchmark on target hardware for regression decisions.

## Versus Array of Structs

The plots below show the iteration time per entity in the classical Position-Velocity example.
That is, iterate all entities with components `Position` and `Velocity`, and add velocity to position:

```mojo
position.x += velocity.x
position.y += velocity.y
```

The benchmark is performed with different amounts of "payload components",
where each of them has two `Float64` fields, just like `Position` and `Velocity`.
Further, the total number of entities is varied from 100 to 1 million.

![AoS-benchmarks](images/aos_benchmark.svg)

Note that the benchmarks run in the Github CI, 
which uses very powerful hardware.
Particularly, the processors have 256MB of cache.
On a laptop or desktop computer with typically much less cache,
Larecs🌲 will outperform AoS for everything but the smallest setups.

## PR-to-PR performance checks

`pixi run performance-check --base <revision>` compares the current library
with another Git revision on the same machine. Without `--base`, local runs
compare the working tree against committed `HEAD`; GitHub PR runs use the exact
PR base SHA, and main-branch push runs use the previous push commit. The tested
current revision is the checkout SHA (normally the PR merge commit in CI).
The complete `pixi run tests test` command runs the gate on Linux and macOS
following correctness tests. Focused test-file runs omit it.

The coordinator builds the same current driver against both source trees with
the installed Mojo compiler, using optimized builds without tracing, debug
information, or sanitizers. It warms both binaries, then runs five pairs,
alternating baseline/current order. A case becomes a candidate only if four
pairs and the paired medians show **over 30% slowdown and over 500 ns extra
operation/frame time**. Candidates are checked in a fresh five-pair round;
only candidates recurring in both rounds fail. Invalid/incomplete reports,
incorrect results, compilation failures, unavailable baselines, and timeouts
fail rather than silently skipping coverage.

The two focused drivers avoid the expensive complete benchmark registry:

| Core case | Sizes | Timed work | Excluded setup and validation |
| --- | --- | --- | --- |
| `access` | 512/2,048 matching rows | Stable-ID component reads and integer checksum | World construction; exact per-entity payload checks |
| `query` | 512/2,048 matching rows | Fresh filtered iterator, row visits, and checksum | Construction of two matching archetypes and equally many excluded tag-only rows; payload checks |
| `execute` | 512/2,048 rows | Ordinary CPU dispatch and integer increments | Construction; check every row's accumulated increments |
| `selected_execute` | 64 selected rows amid 512/2,048 background rows | CPU dispatch over a reusable contiguous selection | Construction and selection creation/release; selected and untouched-row checks |
| `selected_mutation` | Same selection/background sizes | Add/remove a tag, including partial-archetype movement and location repair | Construction; final membership, absence of tags, payload, and background-location checks |
| `batch_cycle` | 512/2,048 rows | Batch creation, payload initialization, removal, and recycling | World construction and first validation/warmup cycle; recycled payload, membership, and surviving control-row checks |

Core calibration doubles from 8 to at most 8,192 operations, stopping at 5 ms
per case. Fast cases can reach the cap first. Each duration is **per complete
operation**, not per entity. Read cases consume the checksum inside the timer;
execution writes are checked after timing, with observable lengths consumed
inside the timer. Spatial boundaries and its unchanged matrix are below.

Run one driver with `pixi run core-benchmarks` or `pixi run spatial-benchmarks`.
Select a gate with `pixi run performance-check --suite core --base <revision>`
or `--suite spatial`; repeat `--suite` to select multiple drivers. The original
`pixi run spatial-performance-check` remains a spatial-only compatibility command.

Reports default to the ignored `output/performance/` directory; use `--output`
to choose another directory. `report.json` includes the schema version,
requested/resolved/effective baselines, current checkout SHA and dirty state,
driver SHA-256 hashes, compiler, OS/CPU, thresholds, compilation and sampling
costs, all paired measurements, and both confirmation rounds when needed.
`summary.md` gives median times, paired changes, candidates, and confirmed
failures. Process logs retain build, warmup, execution, and error diagnostics.
GitHub adds the Markdown to the job summary and uploads the reports/logs as
`performance-<runner>-<attempt>` artifacts for 30 days, including failed checks.
This uses read-only PR permissions and works without publishing PR comments.
Require the existing build/test checks in branch protection to enforce the gate.

The initial unchanged-library comparison against `688fb67` on Apple M4,
macOS 27 arm64, Mojo 1.0.0 (`ed45d567`), took **55.3 seconds**: core builds
9.3/9.6 seconds and sampling 2.6 seconds; spatial builds 5.8/5.4 seconds and
sampling 22.2 seconds. Builds and samples ran sequentially; no concurrent
builds or benchmark jobs ran. These are driver compilation costs in an already
installed environment, not dependency installation time. Linux and hosted macOS
measurements are captured in the PR's artifacts. Confirmation adds sampling
cost for affected suites; command deadlines bound failures rather than promising
a one-minute runtime for all error/confirmation paths.

There are no checked-in machine-specific golden timings. Driver changes affect
both sides; compare historical evidence only when hashes and environments are
compatible. Compiler upgrades do not measure compiler-to-compiler changes.
These broad thresholds target substantial regressions on shared runners;
smaller or cumulative regressions, larger worlds, heap-backed payloads, disjoint
selections, and GPU costs need focused measurements or future coverage. See
[decision 0011](../../design/decisions/0011-pr-performance-regression-checks.md)
and the [roadmap](../../roadmap.md#performance-regression-coverage).

## Small spatial benchmarks on every PR

Run `pixi run spatial-benchmarks` for one bounded CPU-only comparison, or
`pixi run spatial-performance-check --base <revision>` for a regression check.
The complete `pixi run tests test` command runs this suite through the shared
coordinator after successful correctness tests, on both Linux and macOS PR
runners. Focused test-file runs omit it. The existing 100,000-row maintenance benchmark and the full benchmark
suite remain manual measurements.

The small driver uses **512 and 2,048 entities**, one archetype, an integer cell
key and a 128-byte SIMD payload per row. It inserts rows in a deterministic
scrambled order, then compares the same stable-ID cell visits before and after
spatial ordering. Its 32 cases cover:

| Workload | Cell distribution | Timed work |
| --- | --- | --- |
| Static cell aggregates | Uniform: 8 entities/cell | Read keys and all payload lanes; sum and square each cell's aggregate |
| Static cell aggregates | Dense: 64 entities/cell | Same operation, with fewer occupied cells |
| Static cell aggregates | Sparse: 8 entities/cell, key gaps of 1,024 | Same operation across nonconsecutive occupied keys |
| Maintenance alone | All three distributions | Full ordered scan, or reverse keys and sort/move/repair every pass |
| Moving cell aggregates | Uniform | Update every entity's cell, aggregate cells, maintain every frame or every fourth frame |

Static workload timing excludes construction, registration, and the initial
maintenance pass. Mobile timing includes input updates and the selected
maintenance cadence; its scrambled control performs the same updates and cell
visits without maintenance. Maintenance-only reversal is included in timing.
Checksums validate aggregate results and payload preservation, and a query
validates maintenance's output order, outside the timer. These are synthetic
cell aggregates; full neighborhood algorithms, additional archetypes, transfer
costs, and larger working sets remain separate measurements.

Each batch doubles from 8 to at most 8,192 frames, stopping once it takes 20 ms.
The checker compiles **the same current driver** against the current library
and the PR's base commit, warms both binaries, then collects five paired runs
with alternating execution order. It reports median frame times and paired
changes for both ordered and scrambled controls. A case fails only when at
least four pairs show both
**over 30% slowdown and over 500 ns extra time**, and the paired medians exceed
those thresholds. A suspected regression must recur in a fresh five-pair run.
This broad threshold catches substantial regressions on shared runners;
smaller changes need dedicated measurements. No machine-specific timing
baseline is checked in.

The baseline comes from the GitHub PR event's base SHA. Local runs default to
committed `HEAD`; pass `--base` to compare another revision. An unavailable full
SHA is fetched over public HTTPS. Since release PR #174 predates the spatial
API, spatial PR #175 bootstraps against `42234f3b43d4dda58a674842374115f78ec2f08d`,
the implementation before this benchmark addition. Subsequent PRs whose base
has the spatial API use their actual base. Compilation, malformed/missing
records, checksum failures, and sustained regressions all fail the check.
