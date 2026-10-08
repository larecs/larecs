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

## Shared CPU execution comparison

The focused selection driver also measures thin and lexical CPU kernels over
seven matching archetypes (512 rows each) alongside six nonmatching archetypes
(512 rows each). All matching rows perform the same increment; the closure also
counts range invocations. Construction and result checks are excluded, and
checks outside the timer verify row count, every row against `Bencher.num_iters`,
and the closure's exact invocation count and accumulated values.
These cases remain manual benchmarks; they are not added to the small PR suite.

On Apple M4, macOS 27.0.1, Mojo 1.0.0 (`ed45d567`), the shared CPU setup refactor
in `1cd32ba` was compared with `688fb670c87ced6b08c920e2c3527a1890218c6f`
using the **same updated driver** and compiler environment. Build one optimized
binary against an isolated baseline checkout and one against the current source, without
`-g`, sanitizers, or tracing. Warm each once, then alternate baseline/current
order across five paired samples with no concurrent builds or benchmark jobs.
The driver uses fixed iterations: 100 full-world calls, 1,000 multi-archetype
calls, 10,000 contiguous selected calls, and 1,000 disjoint selected calls.

| CPU workload | Baseline median | Refactor median |
| --- | --- | --- |
| 100,000 rows, full-world thin | 23.33 µs | 22.89 µs |
| 3,584 rows, seven matching archetypes, thin | 1.269 µs | 1.034 µs |
| Same rows, lexical closure | 1.089 µs | 0.885 µs |
| 64 selected contiguous rows in a 100k world | 69.0 ns | 18.5 ns |
| 64 selected disjoint single-row ranges in a 100k world | 690 ns | 257 ns |

The unchanged mutation controls measured 10.13 → 10.09 µs for a 64-row
add/remove chain and 107 → 98 µs for the first 512-row disjoint mutation pass.
The existing selected GPU case ran on the actual Apple M4 accelerator and
measured 276.31 → 267.52 µs. These short synthetic batches are local evidence,
not portable timing baselines or application speedup claims. Full-world row
work dominates discovery at 100k rows; small selections benefit from avoiding
matching-range allocation. Compilation is excluded from every operation timing.
The initial baseline driver build took 18.65 seconds; a repeated current build
took 1.36 seconds with local compiler caches populated. These build times are not comparable cold-compilation
measurements and establish no compilation speedup. Linux operation timings
remain unmeasured locally.

Reproduce with the current driver against both libraries:

```sh
pixi run mojo build -I /path/to/baseline/src benchmark/entity_selection_benchmark.mojo -o /tmp/larecs-selection-base
pixi run mojo build -I src benchmark/entity_selection_benchmark.mojo -o /tmp/larecs-selection-current
/tmp/larecs-selection-base
/tmp/larecs-selection-current
```

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
failures. Candidates whose confirmation did not finish are labeled unconfirmed;
only a completed confirmation can label a candidate transient. Process logs
retain build, warmup, execution, and error diagnostics.
GitHub adds the Markdown to the job summary and uploads the reports/logs as
`performance-<runner>-<attempt>` artifacts for 30 days, including failed checks.
This uses read-only PR permissions and works without publishing PR comments.
Require the existing build/test checks in branch protection to enforce the gate.

The initial unchanged-library comparison against `688fb67` on Apple M4,
macOS 27 arm64, Mojo 1.0.0 (`ed45d567`), took **55.3 seconds**: core builds
9.3/9.6 seconds and sampling 2.6 seconds; spatial builds 5.8/5.4 seconds and
sampling 22.2 seconds. Builds and samples ran sequentially; no concurrent
builds or benchmark jobs ran. These are driver compilation costs in an already
installed environment, not dependency installation time.

The first [hosted run](https://github.com/larecs/larecs/actions/runs/37112210067)
compared the same unchanged library against `688fb67`, using PR merge checkout
`ba8b180`, Mojo 1.0.0 (`ed45d567`), the same current driver on each side, fresh
output binaries, sequential compilation/sampling, and five alternating pairs.
Both suites passed without confirmation, and both artifact uploads succeeded:

| Runner | CPU / OS | All driver builds | All sampling | Total gate |
| --- | --- | ---: | ---: | ---: |
| `macos-latest` | Apple M2 Pro (Virtual), macOS 26.6.2 arm64 | 43.1 s | 22.1 s | 66.1 s |
| `ubuntu-latest` | AMD EPYC 7763, Linux 6.17 x86_64 / glibc 2.39 | 50.2 s | 24.6 s | 75.3 s |

These are one-run runtime measurements, not speed comparisons between platforms
or evidence that the runner's load is stable. Full correctness tests, examples,
package checks, and environment installation are excluded from these gate
costs. The combined check stays near a minute; further coverage requires new
budget measurements on both platforms. Confirmation adds sampling cost for
affected suites; command deadlines bound failures rather than promising
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
| Maintenance alone | All three distributions | Clean explicit boundary, or reverse keys via stable-ID access and sort/move/repair every pass |
| Moving cell aggregates | Uniform | Update every entity's cell, aggregate cells, maintain every frame or every fourth frame |

Static workload timing excludes construction, registration, and the initial
maintenance pass. Mobile timing includes input updates and the selected
maintenance cadence; its scrambled control performs the same updates and cell
visits without maintenance. Maintenance-only reversal and conservative marking via mutable stable-ID access
are included in timing. A clean ordered boundary uses deferred maintenance in the
current library and full classification in older baseline libraries. This is an
intentional maintenance-contract change; use the dedicated comparison below for
an explicit full-scan control.
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


## Deferred dirty classification

Build `pixi run mojo build -I src benchmark/dirty_spatial.mojo -o /tmp/larecs-dirty-spatial`,
then run that binary with no concurrent compilation or benchmark jobs.
It constructs identical scrambled 2,048/32,768-entity worlds with 72 component
bytes per row plus entity IDs, establishes initial spatial order, warms both
paths, and alternates five paired samples of sixteen frames (1,024 frames for
clean boundaries to resolve their small cost). The 24 scenarios
cover uniform (16 entities/cell), dense (256/cell), and sparse (16/cell with
key gaps of 128) distributions, with 0, 1, 1/64, or all identities updated.
Each updated identity receives two reference writes per frame; classification
observes final values. On alternating frames those writes cancel. Other frames
advance cells by one. Both paths perform identical updates and semantic work.

The deferred path uses automatic tracking. Its control requests a full rebuild
after those same writes. Timings include updates, marking, key scratch allocation,
classification, sorting, typed movement of all columns, and location repair.
Construction, registration, initial maintenance, and correctness checks are
excluded. Every sample validates complete key order, each identity/location,
the expected final input for every identity, and all eight payload lanes outside timing through read-only queries. Output
records rows, distribution, dirty count, pair number, and deferred/full frame ns.
This compares current deferred maintenance with current explicit full rebuilds;
it does not measure a historical implementation or total application speedup.

Clean calls do no row work. Dirty calls still copy O(entity-ID capacity) keys
and inspect affected archetypes, so sparse classification is not O(D) complete
maintenance. Full rebuilds currently reset sparse membership and caches. Dense
updates may favor contiguous full classification; structural-heavy workloads
use full rebuilds. Retained keys/membership cost at least nine bytes per allocated
ID plus queue capacity (full ID/generation identities and allocator slack).
Scratch and movement metadata add temporary memory. These are layout costs,
not measured application memory usage.
