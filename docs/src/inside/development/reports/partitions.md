+++
type = "docs"
title = "Partition layout measurements"
weight = 5
+++

These comparisons have distinct layouts and environments. The Linux report
compares growable stores with 256-row-capped blocks; the macOS report compares
historical bounded blocks with row reordering. Keep those controls separate.
The growable results were recorded in documentation commit `6d7c2ea`; its text
does not identify an exact current implementation SHA beyond decision 0014.
The macOS comparison does identify its implementation and base revisions.
Below, "current" refers to the candidate in each comparison.

## Partitioned storage comparison

Build the optimized standalone driver once:
`pixi run mojo build -I src benchmark/partitioned_spatial.mojo -o /tmp/larecs-partition-benchmark`.
Run that binary without concurrent compilation or benchmark jobs. Partitioning
is explicitly selected at registration; the control is the **same current
library's deferred row reordering**, not forced full classification or a
historical library with different invalidation costs. The existing core/spatial
PR gate separately measures changes to the default paths against the exact base.

The driver constructs identical deterministic scrambled 2,048/32,768-row worlds
with two component-defined archetypes, 64-byte SIMD payloads, an integer input,
and an additional eight-byte column on half the rows. It compares one growable
store per logical cluster with row reordering for uniform (16 identities per cell), dense
(1,024 per cell), and singleton sparse (one identity per cell, key spacing 128)
distributions. Each configuration warms both layouts with one sixteen-frame
batch, then alternates their order for five paired sixteen-frame samples.

The 48 scenarios cover maintenance with 1, 1/64, or all identities updated;
ordinary read-only query scans and host execution with unchanged layouts;
and complete cell frames with the same updates, maintenance every frame (or
every fourth frame for 1/64 updates), all-lane per-cell aggregation, and cyclic
adjacent-cell aggregate products. Both layouts use identical entities, input
updates, and semantic work. The scan controls still call the clean boundary.
All measured update frames include marking, pending key allocation/copy,
classification, directory construction or sorting, column growth/movement,
source swap-removal, location repair, and allocation reclamation as applicable.
Cell frames also include query setup, cell scratch allocation, aggregation,
and neighbor arithmetic. Construction, initial placement, policy/device setup,
and validation are excluded. There are no device transfers in these CPU timings.

Every sample checks all identities once, final inputs, all payload lanes,
entity locations, default key order or homogeneous cluster stores, and equal
complete spatial checksums outside timing. Query/host scan reductions are also
checked against their complete expected sums. Results are consumed inside the
timer. This is a synthetic spatial workload, not a game/simulation speedup,
collision detection, or a persistent neighbor index.

`MEMORY` records report initial maintained **capacity-derived owned bytes**;
`MEMORY_AFTER_MOVEMENT` reports retained buffers after 96 fully moving frames:
physical-directory slots, component/ID buffers, entity locations, key/dirty
caches, queued identities, and recycled-slot capacity. Counted allocations are
physical-directory plus row-column/ID allocations. Graph/pool allocations,
allocator overhead, device state, classifier configuration, and all temporary
maintenance/query/cell scratch are excluded; these records are not RSS or peak
memory measurements. The components are trivial and have no hidden payload heap.
Columns in a store share capacity, but each column and the IDs allocate
separately. `PAIR` records give rows, distribution, mode, update count, cadence,
pair index, reordering ns/frame, and partition ns/frame.

### Growable-store comparison on Linux

The same current driver was built against committed base `df0e6c5638beaab2bf3784a2b4784044a7c2707e`
(256-row-capped blocks) and the growable-store implementation from decision 0014.
This local run used **AMD Ryzen 7 PRO 5850U, Linux 7.2.5-3-omarchy x86_64,
Mojo 1.0.0 (`ed45d567`)**, normal optimized builds without tracing, sanitizers,
or debug information. Cold builds ran sequentially and took **11.13 s / 11.11 s**
(base/current). No other builds or benchmark jobs ran during timing; background
desktop services remained active. Five pairs of fresh binary invocations alternated
base/current order. Each invocation used the warmup, five paired sixteen-frame
samples per case, timing boundaries, and complete validation described above.
Values below are medians of the five per-invocation medians, in milliseconds.
All 48 cases validated in all ten invocations. Median complete driver execution
including validation was **13.10 s / 11.33 s** (base/current).

Driver SHA-256: `37795c49baa95f1b911d43327d413097b85a5f60f92f3137accf7abfa9a90ad9`.

| Distribution | Timed work, 32,768 rows | Capped blocks | Growable stores | Growable / capped |
| --- | --- | ---: | ---: | ---: |
| Uniform | Maintenance, 512 updates/frame | 0.416 | 0.256 | 0.61 |
| Dense | Maintenance, 512 updates/frame | 0.111 | 0.072 | 0.65 |
| Dense | Complete frame, all moving | 6.032 | 4.295 | 0.71 |
| Singleton sparse | Complete frame, all moving | 20.400 | 17.231 | 0.84 |
| Dense | Ordinary query scan, clean | 0.430 | 0.427 | 0.99 |
| Dense | Ordinary CPU scan, clean | 0.030 | 0.031 | 1.03 |
| Uniform | Ordinary CPU scan, clean | 0.068 | 0.070 | 1.03 |
| Singleton sparse | Ordinary CPU scan, clean | 0.337 | 0.344 | 1.02 |

Dense initial placement used **64 stores and 225 counted allocations**, versus
128 blocks and 449 allocations in the base. Initial counted owned bytes fell
from 4,448,265 to 4,403,209. After 96 fully moving frames, growable dense stores
retained **7,847,945 bytes and 64,512 row slots**, versus 5,062,665 bytes and
32,768 slots for capped blocks. Destination stores can grow while their old rows
are still awaiting transfer, and nonempty stores retain that spare capacity.
Fewer stores therefore do not guarantee less retained memory. These remain
capacity-derived buffer measurements, with the exclusions described above.

Full scans changed by -0.8% to +4.3% across these distributions; small timing
differences on this desktop runner do not establish a scan improvement.
Maintenance and fully moving frame results favor growable stores here, but
singleton clusters still have separate allocations and substantial traversal
overhead. This is CPU-only synthetic evidence; macOS, GPU, application, peak
memory, and additional component-width comparisons remain on the roadmap.
Local raw reports are retained under `output/performance/growable_clusters/`.

### Historical bounded-block comparison on macOS

The measurements below are historical evidence for decision 0013’s
256-row-capped blocks, not timings for the current growable-store layout.
Dense clusters now use fewer stores; sparse clusters still require separate
allocations. Rerun the driver before making performance claims about the new layout.

A local optimized run on **Apple M4, macOS 27.0.1 arm64, Mojo 1.0.0
(`ed45d567`)**, implementation `f3d99cd` (base `6037850`), built in
**7.59 seconds** and completed
execution/validation in **8.88 seconds**.
Driver SHA-256: `da005387b10958c875771cdfb16cebbe455aa7e883631ef36f021734f355a787`.
No concurrent builds or benchmark jobs ran. Representative medians across five
warmed pairs for 32,768 rows were:

| Distribution | Timed work | Updates / cadence | Reordering | Partitions | Partition / reorder |
| --- | --- | --- | ---: | ---: | ---: |
| Uniform | Maintenance | 1 / every frame | 0.626 ms | 0.336 ms | 0.54 |
| Uniform | Maintenance | 512 / every frame | 1.334 ms | 0.381 ms | 0.29 |
| Dense | Maintenance | 1 / every frame | 0.600 ms | 0.017 ms | 0.03 |
| Dense | Maintenance | 512 / every frame | 1.348 ms | 0.096 ms | 0.07 |
| Uniform | Complete cell frame | 512 / every fourth frame | 0.627 ms | 0.393 ms | 0.63 |
| Dense | Complete cell frame | 512 / every fourth frame | 0.651 ms | 0.293 ms | 0.45 |
| Uniform | Complete cell frame | All / every frame | 1.956 ms | 2.785 ms | 1.42 |
| Dense | Complete cell frame | All / every frame | 1.881 ms | 3.125 ms | 1.66 |
| Singleton sparse | Complete cell frame | All / every frame | 1.357 ms | 17.011 ms | 12.54 |
| Uniform | Ordinary query scan | Clean | 0.149 ms | 0.175 ms | 1.17 |
| Dense | Ordinary query scan | Clean | 0.149 ms | 0.148 ms | 0.99 |
| Singleton sparse | Ordinary query scan | Clean | 0.149 ms | 0.237 ms | 1.59 |
| Uniform | Ordinary host scan | Clean | 0.019 ms | 0.045 ms | 2.36 |
| Dense | Ordinary host scan | Clean | 0.019 ms | 0.022 ms | 1.16 |
| Singleton sparse | Ordinary host scan | Clean | 0.020 ms | 0.155 ms | 7.92 |

Initial maintained capacity and allocation evidence for those worlds:

| Layout / distribution | Counted owned bytes | Counted row/directory allocations | Partition blocks | Row capacity / live rows |
| --- | ---: | ---: | ---: | ---: |
| Reordering, all distributions | 4,359,561 | 8 | 0 | 32,768 / 32,768 |
| Partitions, uniform | 7,241,737 | 14,337 | 4,096 | 32,768 / 32,768 |
| Partitions, dense | 4,448,265 | 449 | 128 | 32,768 / 32,768 |
| Partitions, singleton sparse | 27,426,825 | 114,689 | 32,768 | 32,768 / 32,768 |

All initial blocks were fully occupied at their allocated capacities. Component
capacity alone therefore understates partition overhead: physical-store metadata
and many separate allocations matter, especially for singleton clusters. At
2,048 rows counted bytes were 273,801 for reordering versus 452,617 uniform,
278,025 dense, and 1,714,185 singleton partition storage. After 96 fully moving
frames, counted retained bytes were **4,883,849** for
reordering versus **10,116,809** uniform, **5,062,665** dense, and **51,019,785**
singleton partitions at 32,768 rows. Uniform partition row capacity grew to
58,320; dense/singleton row capacity remained 32,768. Empty blocks released their
row allocations, while partial block growth and high-water directory/queue
capacity remained. These are retained-buffer measurements, not peak memory.

Small dense/uniform updates took less elapsed maintenance time with partitions,
while directory rebuilding and per-block scans dominated singleton cases. The
benchmark measures total elapsed costs, not byte-movement counters.
Fully moving workloads were slower despite local transfer. Keep partitions
opt-in, and retain the reordering default. The measured bounded-block
implementation copied identity-capacity keys,
inspected blocks, and could move unchanged rows during same-cluster compaction.
The current layout retains key copying and directory scans but removes
cross-block compaction; destination growth can still relocate existing columns.
Cluster selection scans metadata. Application workloads,
other component widths, structural-heavy frames, Linux comparative timings,
process/peak memory, and device timings remain on the roadmap. GPU functional
integration ran on the actual local accelerator; it is separate evidence from
these CPU performance measurements.

The separate default-path PR gate against `6037850` passed all twelve core and
32 spatial cases in **49.2 seconds**, including four sequential builds and five
paired samples. It required no regression confirmation. Ordinary 2,048-row
query/host execution changes were +0.1%/-0.6%, stable-ID access was +3.9%, and
selected mutation was +0.9% in that run. These small shared-machine differences
are not a zero-overhead guarantee; the existing 30%/500 ns rule is unchanged.
Hosted Linux/macOS evidence is retained by the PR checks.
