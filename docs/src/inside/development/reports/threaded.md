+++
type = "docs"
title = "Threaded host measurements"
weight = 2
+++

The measurements below concern the implemented engine at `4489ceb`, on AMD
Ryzen 7 PRO 5850U, Linux x86-64, Mojo 1.0.0 (`ed45d567`), MAX 26.5.0.
The [host-dispatch feasibility investigation](../../design#research-and-historical-evidence)
retains a different prototype and must not substitute for this engine.

## Threaded host execution

`benchmark/threaded_execution.mojo` measures the implemented public
`SystemContext.run[kernel, threaded=True]()` against unchanged sequential calls.
Both worlds have identical initial rows, arithmetic, and layout. The driver
covers 1/2/4 worker tasks, one/four stores, balanced and seven-to-one skewed
stores, 1,024–1,048,576 total rows, and increments or 32 dependent arithmetic
rounds per row. It forces `min_parallel_rows=0` to expose dispatch overhead;
configured one-worker runs still use whole-range sequential fallback.

Each case warms both paths twice, calibrates the sequential path to a 10 ms
batch or at most 4,096 calls, then alternates order across five paired samples.
Complete-call timing includes discovery, validation, spatial-invalidation checks,
resource binding, context allocation, atomic claiming, dispatch, join, cleanup,
and world-size consumption. Construction, initial runtime warmup, compilation, and exact result
validation are excluded. Every final row is validated against all warmup,
calibration, and measured calls. No resources or spatial classifiers are bound;
shared-resource, selected, and partitioned correctness lives in the tests,
while their performance remains unmeasured here.

```sh
pixi run mojo build -I src benchmark/threaded_execution.mojo -o /tmp/larecs-threaded-benchmark
/tmp/larecs-threaded-benchmark
/tmp/larecs-threaded-benchmark
/tmp/larecs-threaded-benchmark
```

Build once without debug info, tracing, or sanitizers. Run measurements without
other builds or benchmark jobs. Each `PAIR` line contains skew flag, base rows
per store, store count, arithmetic rounds, worker count, pair index, calls per
batch, sequential ns/call, and threaded ns/call. In skewed cases, total rows
are ten times the base row count. Report compilation separately and retain
hardware/compiler details; this synthetic comparison establishes no portable
cutoff, fixed speedup, or application-level benefit.

At revision `4489ceb`, on Linux x86-64 (`7.2.5-3-omarchy`), AMD Ryzen 7 PRO
5850U (8 cores, 16 hardware threads), Mojo 1.0.0 (`ed45d567`), and MAX 26.5.0,
the optimized build took 17.57 seconds in the installed environment; this is not a cold-cache
compilation measurement. Three serial binary runs took 7.12, 7.48, and 7.70
seconds after regression builds completed. All 30 scenarios and 450 paired
measurements passed exact result validation. Raw local output is retained in
ignored `output/threaded-execution/run-{1,2,3}.txt` files.

Four-worker results below summarize 15 pairs per case. Times are medians in
microseconds per complete call; speedup is the median paired ratio, so it need
not equal the ratio of the displayed medians.

| Total rows | Stores | Work per row | Sequential µs | Threaded µs | Speedup |
| ---: | ---: | --- | ---: | ---: | ---: |
| 1,024 | 4 balanced | increment | 0.718 | 16.072 | 0.04× |
| 65,536 | 4 balanced | 32 rounds | 1,869.585 | 550.040 | 3.44× |
| 262,144 | 1 | increment | 100.969 | 46.486 | 2.24× |
| 1,048,576 | 4 balanced | increment | 406.295 | 141.176 | 2.95× |
| 1,048,576 | 1 | 32 rounds | 32,106.429 | 8,967.991 | 3.50× |
| 163,840 | 4 skewed | 32 rounds | 4,999.816 | 1,455.091 | 3.39× |

This is one developer machine with unpinned affinity and frequency. Tiny
increments lose substantially when the row cutoff is explicitly disabled;
the default cutoff avoids that dispatch. These measurements cover neither
macOS arm64 nor application kernels, shared-resource workloads, exact selections,
spatial maintenance, or partitioned layouts. The engine remains experimental.
