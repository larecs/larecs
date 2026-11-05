# Storage range migration evidence

The #170 migration replaces start-index mutation iterators with bounded storage
ranges under [decision 0022](../decisions/0022-locked-storage-ranges.md), retaining
shared query membership, independent cursors, and the existing mutation engines.

## Performance assessment

On 2026-11-04, compare PR212's `8d805882487dd5091a78829396d746b103893b97`
with implementation `7d4e1afb1967001a592fb6e3aade200d8d3aa3b9` on an Apple M4,
macOS 27.0.1 (26A434), Mojo 1.0.0
(`ed45d567`). Both libraries use the same current checked-in
`benchmark/entity_selection_benchmark.mojo` and `benchmark/migration_benchmark.mojo`
drivers. Export baseline sources with `git archive`; build each driver once
against each library with `mojo build -I <library-src> -I benchmark`, without
debug information, sanitizers, or tracing. Compilation is excluded from operation
timings; no cold compilation cost was measured.

Warm both binaries once, then collect three pairs, alternating baseline/current,
current/baseline, baseline/current. The migration driver also warms each workload
internally. It covers 1,024 and 65,536 entities and five component changes per
cycle; construction is excluded. The selection driver's existing fixed iteration
counts and timing boundaries are unchanged, including full-world execution,
64-row contiguous/disjoint selections, mutation chains, and an actual Metal run.

**These are diagnostic samples, not controlled regression evidence.** Process
snapshots before every sample found concurrent compiler/test jobs from sibling
worktrees. The unchanged single-entity control also varied materially. The large
batch difference cannot be attributed to this refactor from these samples;
repeat isolated measurements before drawing a regression or speedup conclusion.
The [roadmap](../../roadmap.md) retains that measurement work.

| Workload | Baseline median ns/call | Revised median ns/call |
| --- | ---: | ---: |
| Full-world host execution, 100,000 rows | 48,060 | 48,370 |
| Host contiguous selection, 64 rows | 42.5 | 42.6 |
| Host disjoint selection, 64 rows | 515 | 517 |
| Selected add/remove chain, 64 rows | 21,140 | 21,120 |
| Selected disjoint first-pass mutation, 512 ranges | 226,000 | 226,000 |
| Device contiguous selection, 64 rows | 337,530 | 339,510 |

| Migration workload | Baseline median ns/entity/cycle | Revised median ns/entity/cycle |
| --- | ---: | ---: |
| Single-entity control, 1,024 rows | 233.94 | 221.13 |
| Whole-archetype batch, 1,024 rows | 39.13 | 35.50 |
| Single-entity control, 65,536 rows | 242.80 | 311.88 |
| Whole-archetype batch, 65,536 rows | 35.45 | 44.25 |

The allocation preservation claim rests on runtime identity checks: archetype
indices and explicit range metadata share their owners across copies, while
cursor positions and guard bits remain independent. Ordinary queries do not
allocate explicit range triples. These facts do not establish an application
speedup.

The bounded core checker also compared the same current driver against PR212:
`pixi run performance-check --base 8d80588 --suite core`. All twelve cases
completed five paired samples without a sustained regression candidate. The
observed optimized builds took 45.45 s for baseline and 50.64 s for revised
sources; warmup/sampling took 5.52 s. These compilation measurements include
concurrent-build interference and are not cold-cache costs. The same interference
limits the timing conclusion even though the diagnostic gate completed.

## Focused validation

The complete `pixi run tests --parallel 2 test` attempt was interrupted after
37 of 39 files: 35 passed and two reported the physical-store count defect from
a pre-fix precompiled library. The lifecycle and world builds did not finish.
This is not an uninterrupted clean full-suite result; the fresh focused runs
below verify the corrected implementation.

- Thirteen iterator runtime regressions and five compiler rejection/control pairs
  cover tracked origins, read-only queries, noncopyable/scoped selections,
  shared metadata, independent cursors/locks, and exceptional cleanup.
- Twenty-four world tests and twenty-one selection tests cover low-level batch
  compatibility and selected mutation/execution chains.
- Three selection device tests executed on the M4; the separate GPU guard probe
  skips unavailable guard support. A passing skip is not GPU guard coverage.
- The three affected guide doctests were extracted and executed with the normal
  sanitizer runner. The standalone `doctest` task had no generated `docs/test`
  directory, so its empty run is not counted as validation.
- API documentation, the satellites example, and the migrated GPU benchmark
  compile. A separate runtime probe verifies every initialized orbital row;
  the full orbital arithmetic benchmark was not timed.

The full sanitizer run exposed a physical-store aggregation case: three source
clusters appended to one destination, but the first bounded implementation
reported only 11 of 33 changed rows. Extend the existing destination range for
every subsequent source append. The corrected thirteen-test iterator suite
passes with sanitizers, including multiple physical sources, a pre-existing
destination prefix, copied cursors, and post-mutation maintenance. The existing
heap-backed partition bulk add/replace/remove regression also passes in the
focused optimized probe.

After the physical-store correction, rerun both bounded suites against PR212
at source revision `323973fcaff6ed2ec987eb77332fb1976a04c310`:
`pixi run performance-check --base 8d80588`. All 12 core and 32 spatial cases
pass the five-pair guard with no sustained regression candidate. Concurrent
sibling builds still limit attribution; this is not isolated performance evidence.
The heap-backed bulk regression and the new physical-source/prefix regression
also pass together through the normal assertion-enabled sanitizer runner.

The initial hosted API-doc build exposed a defect already present at PR212
revision `8d80588` in
`systems_scheduler.md`: the second `guide_threaded_execution` block lacks
`global=true`, causing Modo to emit removed `fn` syntax. PR212 contains the same
block. API JSON generation and the three guides affected by this migration passed;
this failure is not reported as a successful complete documentation build.
