---
id: "0011"
title: "Same-runner PR performance regression checks"
status: accepted
status_notes: Initial coverage is a bounded CPU core suite and the existing spatial suite; GPU and large working sets remain manual measurements.
---

# Decision 0011: Same-runner PR performance regression checks

## Context

The complete benchmark registry is too expensive to compile on every PR.
The spatial check already compares paired samples on one runner, but does not
cover general ECS paths or retain machine-readable evidence. Historical times
from different GitHub runners cannot provide a reliable gate.

## Decision

Use one extensible Python coordinator and small, independent Mojo drivers.
Build the **current driver source** once against each library revision, using
the same installed compiler and optimized flags, without debug information,
sanitizers, tracing, or imports of the complete registry. Compile sequentially;
warm both binaries and alternate baseline/current order in five paired samples.
Validate every execution's complete scenario manifest and positive finite times.
Each driver validates semantic results outside its timer and consumes results
inside it. Construction, maintenance, and mutation costs must be documented.

The baseline is the GitHub PR event's exact base SHA, explicit `--base` locally,
or committed `HEAD` for a dirty worktree comparison. Main-branch push checks use
the event's previous commit. Compare the actual CI checkout (normally GitHub's
PR merge commit) and record its SHA, dirty state, driver hashes, compiler version,
platform/CPU, thresholds, separate compilation/execution times, and paired data.
Baseline source extraction accepts only regular files beneath `src/`.

Keep the existing spatial bootstrap only for revisions predating that API;
report the requested and effective baselines separately. No automatic bootstrap
or skip is allowed for core API incompatibilities. An incompatible base fails
compilation with diagnostics, requiring an explicit compatible baseline or an
intentional driver compatibility change.

A case is a candidate regression only when at least four of five pairs exceed
both **30% relative slowdown** and **500 ns per operation/frame**, with paired
medians exceeding both limits. Repeat the candidate suite with fresh warmup and
five pairs; fail only cases that meet the rule in both rounds. Keep both rounds
in the report, including candidates rejected as transient. These inherited
shared-runner limits catch substantial regressions; they do not guarantee
detection of smaller regressions or cumulative small slowdowns.

The initial core matrix covers 512/2,048 rows: stable-ID component access,
filtered query iteration across multiple archetypes, ordinary CPU execution,
64-row selected execution amid unselected rows, selected add/remove chains,
and whole-archetype batch creation/removal. Keep the spatial matrix unchanged.
Use bounded calibration and validate locations, payloads, membership, and
untouched rows as appropriate. The combined normal check should remain near
one minute per runner, including compilation and sampling; record Linux and
macOS timings before expanding it further.

The complete test command runs the coordinator on both existing PR runners.
Focused file tests omit it. CI writes Markdown to the job summary and retains
JSON, Markdown, and process logs as per-run artifacts for 30 days, including
failures. The process exits nonzero for confirmed regressions, invalid reports,
correctness failures, compilation errors, missing baselines, and timeouts.
Use ordinary `pull_request` with read-only repository permissions; no PR
comments, secrets, external benchmark service, or write token is required.

## Rationale

Same-machine, same-driver comparisons isolate library changes and avoid stale
machine-specific golden timings. Pairing and confirmation limit transient-load
failures without masking sustained regressions. Relative and absolute limits
avoid failing tiny operations on timer noise. A bounded CPU suite is useful on
both standard platforms; large registries and GPUs require dedicated resources.
Per-run artifacts make the gate auditable without operating a history service.

## Consequences

Benchmark changes affect both sides of the comparison. Driver hashes identify
the workload; results from different hashes are not a historical time series.
New APIs need explicit compatibility handling. Compiler upgrades compare both
sides under the new compiler and do not measure compiler-to-compiler changes.
Performance status remains part of the existing build/test checks; maintainers
must require those checks in branch protection to prevent merging failures.
An accepted performance tradeoff requires measured evidence and a documented
policy/workload change rather than silently lowering thresholds.

## Evidence

- [Benchmark guide](../../src/guide/benchmarks.md) defines commands and boundaries.
- [Coordinator](../../../scripts/check_performance.py),
  [core driver](../../../benchmark/core_smoke.mojo), and
  [spatial driver](../../../benchmark/spatial_smoke.mojo).
- [Guard tests](../../../test/performance_test.py) cover noise, report validity,
  baseline selection, failure reporting, and confirmation behavior.
- [CI workflow](../../../.github/workflows/main.yml) and
  [test entry point](../../../test/run_tests.sh).
- [Remaining coverage](../../roadmap.md#performance-regression-coverage).

The initial [Linux/macOS PR run](https://github.com/larecs/larecs/actions/runs/37112210067)
passed both full build/test jobs and uploaded both evidence artifacts. With
Mojo 1.0.0 (`ed45d567`), the unchanged-library gate took 66.1 seconds on virtual
Apple M2 Pro/macOS 26.6.2 and 75.3 seconds on AMD EPYC 7763/Linux x86_64.
Driver builds cost 43.1/50.2 seconds and sampling 22.1/24.6 seconds respectively.
See the guide for commit IDs, timing boundaries, and shared-runner limitations.
