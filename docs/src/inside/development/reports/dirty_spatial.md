+++
type = "docs"
title = "Deferred classification measurements"
weight = 4
+++

This report retains M4 results for implementation `76868ef` based on `0241e91`,
with Mojo 1.0.0 (`ed45d567`). The original run did not record an OS build.
The current [maintenance mechanism](../../../architecture/spatial) can differ
from this measured revision; the workloads and timing exclusions follow below.
"Current" below refers to the measured implementation.

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

A local run on **Apple M4, arm64, Mojo 1.0.0 (`ed45d567`)** with implementation
`76868ef` (based on `0241e91`) built the optimized driver in **4.74 seconds**.
Five warmed pairs gave these median complete-frame times for 32,768 entities:

| Distribution | Dirty identities | Deferred | Explicit full rebuild | Deferred/full |
| --- | ---: | ---: | ---: | ---: |
| Uniform | 1 | 0.685 ms | 1.076 ms | 0.637 |
| Uniform | 512 | 0.749 ms | 1.133 ms | 0.661 |
| Dense | 512 | 0.811 ms | 1.194 ms | 0.679 |
| Sparse | 1 | 0.097 ms | 0.490 ms | 0.198 |
| Sparse | 512 | 0.112 ms | 0.497 ms | 0.226 |
| Uniform | 32,768 | 0.850 ms | 0.858 ms | 0.991 |

Across both sizes and all distributions, nonzero sparse-update scenarios took
19.5–67.9% of the full-rebuild frame time. Clean boundaries measured approximately
3–4 ns (close to timer resolution), versus 0.031/0.490 ms full rebuilds at the two
sizes. Fully dirty frames took 99.1–104.6% of the explicit control. An earlier
version that resolved every dirty identity separately took 131–141% for fully
dirty frames; the accepted all-ID-dirty fallback avoids that column/location
setup cost. Neither path can avoid moving clean rows when regrouping demands it.

The separate same-driver PR gate against `0241e91` passed all 12 core and 32
spatial cases in **41.1 seconds** including four sequential compilations and
five paired samples. It found no confirmed regression under the existing
30%/500 ns rule. It still measured approximately **15–19%** overhead for reversing
maintenance, **10–14%** for maintained mobile frames, and **3–8%** for ordinary
stable-ID access. Those costs remain visible tradeoffs, not claims of zero
regression. Linux evidence comes from the PR checks; actual GPU execution is
validated separately and is not included in these CPU performance numbers.
