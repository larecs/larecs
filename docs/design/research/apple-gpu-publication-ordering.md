# Apple GPU publication ordering

Investigated 2026-10-13 for [decision 0016](../decisions/0016-kernel-memory-synchronization.md)
on branch `kernel-synchronization-design`. The change under investigation is
commit `19c50fa` ("allow acquire loads and release stores on Apple GPU"),
compared against its parent `382bd19`.

This is research evidence for one device and toolchain, not a certification of
Apple's GPU memory model. It does not establish an accepted requirement.

## Environment

| Item | Value |
|---|---|
| Machine | Apple M4, 10-core GPU, Metal 4 |
| OS | macOS 27.0.1 |
| Compiler | Mojo 1.0.0 (`ed45d567`), project lockfile |
| GPU builds | No debug info (`-g`), see the Metal crash note in `AGENTS.md` |

## Questions

1. Why does Larecs reject compare-exchange, guards, and non-relaxed orderings
   on Apple GPU?
2. Can acquire loads and release stores be allowed, and do they provide
   cross-block publication on actual hardware?
3. Does allowing them degrade the performance of existing code, and what do
   they cost when used?

## 1. Causes of the Apple restrictions

Before the change, `src/larecs/sync.mojo` rejected these operations on Apple
GPU targets:

- strong `compare_exchange`
  ("Strong compare-exchange is unavailable on Apple GPU in Mojo 1.0"),
- `try_read`/`try_write` guards
  ("Reader/writer guards are unavailable on Apple GPU in Mojo 1.0"),
- every non-relaxed ordering, including loads and stores
  ("Apple GPU publication ordering is not supported by Larecs yet").

To separate compiler limits from Larecs policy, small kernels calling
`std.atomic.Atomic` directly, without Larecs, were built and launched on the M4:

| Upstream operation | Result on Apple GPU |
|---|---|
| Strong `compare_exchange` (relaxed) | Compile error: "Apple GPU only supports `weak` compare-exchange; AIR exposes no strong compare-exchange primitive" |
| `compare_exchange_weak` | Does not exist in Mojo 1.0 (`Atomic` has no such attribute) |
| `fetch_add` with `ACQUIRE_RELEASE` | Compile error: "Apple GPU does not support `acquire_release` atomic ordering" |
| `load` with `ACQUIRE` | Compiles and runs |
| `store` with `RELEASE` | Compiles and runs |

Findings:

- **Strong compare-exchange is a compiler limit.** Metal's AIR only has a weak
  compare-exchange, and Mojo 1.0 exposes no weak variant.
- **Guards follow from that.** `try_read`/`try_write` make exactly one strong
  compare-exchange attempt on the state word and report failure as `Busy`. A
  weak compare-exchange could fail spuriously, which would require a retry loop
  that the nonblocking contract deliberately excludes.
- **Acquire-release read-modify-write is a compiler limit.**
- **Acquire loads and release stores were only restricted by Larecs**, because
  decision 0016 rejects publication orderings on a target until they are proven
  there.

## 2. Allowing acquire loads and release stores

### Change

`AtomicView.load` and `AtomicView.store` no longer call the Apple
relaxed-only check. `fetch_add`, `fetch_sub`, and `compare_exchange` keep it,
with the message "Apple GPU read-modify-write ordering must be relaxed".
Strong compare-exchange and guards remain rejected.

### Lowering

A kernel performing an ordinary store, a release store, an acquire load, and an
ordinary load was built with
`mojo build --target-accelerator apple-m4 --emit llvm`. The AIR module handed to
Apple's compiler contains:

```llvm
store i32 42, ptr %5, align 4
store atomic i32 1, ptr %2 release, align 4
%6 = load atomic i32, ptr %2 acquire, align 4
```

The orderings reach Apple's backend intact; Mojo does not silently relax them.
Whether Apple's closed backend honours them cannot be determined from the IR,
so it was tested on hardware.

### Message-passing experiment

Each slot has 16 ordinary payload words and one atomic flag. Even blocks are
producers: they write the round number into all 16 words with ordinary stores,
then store the round into the flag. Each odd block is the consumer for the
preceding even block: it polls the flag (at most 2^14 times, so no
co-residency is assumed) and, on observing the round, checks all 16 words. A
read is *stale* if any word is not the current round.

Configuration: 128 blocks of 256 threads (16,384 slots), 200 launches with
increasing round numbers, 3,276,800 observed publications per configuration.
Every configuration observed every publication.

| Store / load ordering | Stale reads | Share |
|---|---|---|
| relaxed / relaxed (3 runs) | 3,275,024; 3,273,472; 3,274,080 | ~99.9% |
| relaxed / acquire | 1,852,496 | ~56.5% |
| release / relaxed | 0 | 0% |
| release / acquire (3 runs) | 0; 0; 0 | 0% |

Findings:

- Release/acquire published the payload in every observation.
- The relaxed control shows the experiment can detect missing ordering on
  this hardware; without ordering, stale payload is the norm, not a rare race.
- On the M4 the release store alone was sufficient, while acquire alone was
  not. This is a hardware observation only; the Larecs contract still requires
  the release/acquire pair.

### Repository test

`test_device_publication` in `test/gpu_synchronization_test.mojo` encodes the
experiment at a smaller size (64 blocks, 20 launches). It asserts at least one
observed publication, no more than the slot total, and zero stale reads. It
runs on every accelerator and is skipped without one.

- Three consecutive runs passed (reported test times 11.4 s, 2.0 s, 2.1 s;
  the first includes Metal pipeline creation).
- **Negative check:** replacing the test's release/acquire with relaxed
  ordering made it fail with 163,840 stale reads.
- `scalar_contract` additionally performs a release store and acquire load
  in every lane on every accelerator.

Compile-time diagnostics were rechecked on Apple after the change:
acquire-release and release `fetch_add` report the new read-modify-write
message, strong compare-exchange and guards keep their messages, and an
acquire load plus release store builds and runs. CPU
`test/synchronization_test.mojo` (7 tests) and
`test/check_synchronization_contracts.py` (13 cases) pass.

## 3. Performance

### Method

Following the [benchmark guide](../../src/guide/benchmarks.md): the parent
commit was checked out in a separate worktree, binaries were built once
without debug info, sanitizers, or tracing, warmed, and then run in paired,
alternating order.

### Generated code of existing operations

| Artifact | Parent vs. change |
|---|---|
| CPU assembly of `benchmark/synchronization_benchmark.mojo` (plain, upstream atomic, Larecs atomic, write guard) | Byte-identical |
| Apple AIR of a kernel using relaxed `load`, `store`, `fetch_add`, `fetch_sub` | Byte-identical |

The removed check was a compile-time assertion that emitted no instructions,
so code that compiled before is unchanged.

### CPU timing

`benchmark/synchronization_benchmark.mojo`, 100,000 sequential operations per
sample, 10 paired samples per revision, median nanoseconds per operation:

| Case | `382bd19` | `19c50fa` | Change |
|---|---|---|---|
| plain | 0.25 | 0.25 | +0.0% |
| upstream atomic | 1.78 | 1.78 | +0.0% |
| Larecs atomic | 1.77 | 1.77 | +0.3% |
| write guard | 2.99 | 2.97 | -0.5% |

Differences are within sample spread (for example, write guard ranged
2.90–3.62 ns before and 2.89–3.93 ns after), consistent with identical code.
An earlier `mojo run` of the same benchmark reported higher values (for
example, 12.51 ns for the write guard); those include JIT effects and were not
used for comparison.

### Cost of the new orderings on Apple GPU

Opting into the new orderings is not a regression of existing code, but it
has a cost. A worst-case kernel launched 65,536 threads (256 blocks × 256),
each running 256 iterations of: ordinary store to its own word, flag store,
flag load, ordinary load of a neighbouring word. Each sample timed 10 launches
plus synchronization on the host; variants were interleaved, 7 samples each,
after warm-up.

| Store / load ordering | Median per launch | Relative |
|---|---|---|
| relaxed / relaxed | 269 µs | 1.00× |
| release / relaxed | 696 µs | 2.58× |
| relaxed / acquire | 903 µs | 3.35× |
| release / acquire | 1,056 µs | 3.92× |

This is roughly 50 ns of additional cost per ordered store/load pair per
thread in this kernel. Ordered operations should be used for publication, not
for independent counters, which remain relaxed.

### Test-suite cost

`test_device_publication` adds about 2 s to a GPU test run after Metal
pipeline creation. It is not part of the per-PR CPU benchmark checks.

## Limitations

- One device (M4), one OS, one compiler. Other Apple GPUs and future Metal
  compilers need their own evidence.
- A finite stress test cannot prove the absence of reordering; it shows that
  the experiment detects missing ordering and that none was observed with it.
- The experiment publishes between blocks of one launch. It does not cover
  host/device concurrency, which the API does not permit.
- The GPU cost kernel is a worst case with no other work; application costs
  were not measured.
- Strong compare-exchange, ordered read-modify-write, and guards remain
  unsupported on Apple and are tracked in the
  [roadmap](../../roadmap.md#kernel-memory-synchronization).
