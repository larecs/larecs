# Optimizing GPU system execution

Plan for making `SystemContext.run[..., on_gpu=True]` fast. Every number
below was measured on this machine (Apple M4, Metal backend) before the plan
was written; the measurement scripts are described in "Reproducing the
baseline".

## Baseline

Workload: 1,000,000 entities in one archetype, `Position` and `Velocity`
(8 bytes each, `Float32` pairs), kernel adds velocity into position. This is
the `system_sketch.mojo` workload at 1/10th scale.

Steady-state cost of one `run[on_gpu=True]` call, broken down by phase:

| phase                        | ms   |
| ---------------------------- | ---- |
| archetype scan               | 0.00 |
| device storage allocation    | 0.00 |
| upload (enqueue)             | 3.67 |
| upload (synchronize)         | 0.01 |
| kernel context build         | 0.00 |
| launch (enqueue)             | 0.02 |
| kernel (synchronize)         | 0.98 |
| download (enqueue)           | 4.77 |
| download (synchronize)       | 0.01 |
| **total**                    | **9.24** |

The first call additionally pays 28.6 ms of just-in-time kernel compilation.
The same work on the CPU path takes 0.33 ms.

Three facts follow, and they set the priority order.

1. **92% of the time is host/device transfer.** Upload plus download is
   8.44 ms of the 9.24 ms. The kernel is 0.98 ms, of which 0.16 ms is the
   measured launch-and-synchronize floor for an empty kernel.
2. **The kernel alone is already slower than the entire CPU path.** 0.98 ms
   versus 0.33 ms. For a memory-bound kernel on unified memory there is no
   bandwidth advantage to win. Amortizing transfers is therefore not a
   refinement, it is the precondition for the GPU path being worth choosing
   at all.
3. **The device buffer bookkeeping is doing avoidable work.** A one-line fix
   described in Phase 1 cuts upload from 3.67 ms to 1.54 ms, verified.

## Phase 0: correctness gate — done

The GPU path produces wrong results when a filter matches more than one
archetype. This blocks the rest of the plan, because device residency and
partial download both need a correct row-offset map.

The upload loop in `src/larecs/system.mojo:520` copies each matching
archetype's column with the default `offset=0`, so every archetype overwrites
the previous one at row zero. The download loop directly below it does track
a running offset, so results are scattered back to the wrong rows.

Reproduced with four entities across two matching archetypes:

```
expected: 1.0 11.0 101.0 201.0
actual  : 101.0 201.0 0.0 0.0
```

Fixed by threading the running offset through the upload loop exactly as the
download loop already does, in `src/larecs/system.mojo`. Covered by
`test/gpu_multi_archetype_test.mojo`, a regression test with two matching
archetypes and one non-matching archetype; reverting the fix against that
test reproduces the exact numbers above (`101.0` in place of `1.0`),
confirming the test catches the bug rather than passing vacuously. The full
test suite (`pixi run tests test`, 16 files including the three GPU tests)
passes with the fix in place.

## Phase 1: device storage bookkeeping — done

Small, local, and independently verifiable. Implemented as five fixes plus
one that Phase 0 and this phase together exposed and that had to be fixed
alongside them to make the others safe.

**Fixed the byte-versus-row length comparison.** In
`src/larecs/device_storage.mojo`, `len(self._columns[id].unsafe_value())`
returns a byte count while `self._length` is a row count. Confirmed by direct
probe: `len` on a `DeviceBuffer[DType.uint8]` of 64 bytes returns 64. For any
component wider than one byte the comparison was always unequal, so every
`copy_from_host` allocated a second buffer and did a full device-to-device
copy of the column it had just allocated, even when the size had not
changed. Fixed by comparing `self._length * size_of[T]()` against the
buffer's real byte length. Measured in isolation: upload for an 8 MB column
dropped from 3.67 ms to 1.54 ms.

**Stopped discarding device storage every call.** `SystemContext.run` used
to replace `world._device_storage` with a freshly constructed
`DeviceComponentStorage` on every invocation, whose columns were all `None`.
Every column was therefore reallocated from scratch each call even when
nothing about its size had changed. Fixed by keeping the existing storage
and letting `copy_from_host`'s own per-column growth logic handle sizing,
exactly as it already did for a single call's multiple archetypes.

**Fixed a latent buffer-growth bug this uncovered.** Growing a column
copied the old, smaller buffer into the new, larger one with
`old_buffer.enqueue_copy_to(new_buffer)`. The device copy API requires
source and destination to be the same size — confirmed by direct probe, it
raises "not enough data in src" for a too-small destination request and
"Destination buffer size must be >= source buffer size" for a too-small
source. This path was reachable but never actually exercised with a real
size change before Phase 0 and this phase landed: under the old buggy byte
comparison, growth ran on every call regardless of whether the size had
changed, and the "old" and "new" sizes it computed usually matched by
construction, so the mismatched-size copy never actually had to execute; and
before Phase 0's offset fix, a multi-archetype upload always overwrote
offset zero rather than growing the column for each archetype in turn, so a
column genuinely growing mid-call could not happen either. Fixing the byte
comparison and the offset bug together made this the first time a real
size change reached this code path, and it failed immediately. Fixed by
copying into a same-sized leading sub-buffer of the new, larger buffer
rather than into the buffer directly. Verified with a stress script running
three back-to-back GPU launches over two archetypes each: an initial small
size, then growth to 1,005 entities across both archetypes, then a repeat
launch at the same size to exercise the now-common "no growth needed" path.
All three produced the exact hand-computed sums.

**Used the non-blocking allocator.** `_create_column`, `copy_from_host`, and
`DeviceResourceStorage.upload` called `create_buffer_sync`.
`enqueue_create_buffer` exists and is non-blocking; both measured about
0.03 ms for 8 MB, so this matters mainly once Phase 2 makes allocation less
rare, but there was no reason to block.

**Removed the duplicate synchronize.** `run` used to end with
`device_storage.synchronize()` followed by `device_resources.synchronize()`.
Both forward to `_device_context.synchronize()`, and `device_resources` is
constructed from `device_storage._device_context`, so both shared the same
underlying context. Kept only the first call.

**Removed the dangling-reference pattern.** `run` used to bind
`ref device_storage = self.world[]._device_storage[]` and then immediately
assign a new value to `self.world[]._device_storage`, continuing to use the
old binding. This happened to work because the reference addressed the
`Optional`'s payload slot, which the assignment overwrote in place. Removing
the reassignment (the storage-discard fix above) also removes this pattern:
`device_storage` is now a genuine reference for the rest of the branch.

**Result.** Steady-state cost of one `run[on_gpu=True]` call on the original
baseline workload (1,000,000 entities, one archetype, `Position` and
`Velocity`) dropped from 9.24 ms to a mean of 7.46 ms across four trials
(range 7.20–7.69 ms), about 19% faster. This is less than earlier
per-fix measurements suggested in isolation, because for a single
stable-size archetype the storage-discard fix mostly saves allocation
overhead — already cheap, at 0.03 ms — rather than transfer time; the
content is still fully re-uploaded and re-downloaded on every call
regardless of whether it changed, which is exactly the transfer cost Phase 2
exists to eliminate. The effect is much larger at the low end of the
arithmetic-intensity sweep in `benchmark/gpu_system_benchmark.mojo`, where it
directly targets the fixed cost every entry pays: the 1-step (memory-bound)
GPU entry dropped from a 2.30 ms mean to 1.14 ms, roughly halved, and the
8-step entry's GPU speedup over CPU improved from about 3x to about 6x
(background load differed between the two runs, so treat the ratios as the
comparable figure rather than the absolute CPU milliseconds). This moves the
crossover point further left, meaning fewer floating point operations per
entity are needed before the GPU path pays for itself.

Full test suite (`pixi run tests test`, 16 files) passes, including all
three GPU tests. The correctness fix from Phase 0 remains covered by
`test/gpu_multi_archetype_test.mojo`, now exercising the growth path this
phase fixed on every run rather than only the single-call, single-size path
it exercised before.

## Phase 2: transfer elimination

This is where the remaining time lives. Two independent changes, in
increasing order of design cost.

**Declare per-component access mode on the filter — done.** Today `run`
uploads and downloads every component in the filter unconditionally. Most
systems read some components and write others. In the baseline workload
`Velocity` is read-only, so its download was pure waste; a write-only output
component would likewise not need uploading.

Implemented as `Filter.read[T]`/`Filter.write[T]`, alongside the existing
`Filter.include[T]` (which now marks a component both readable and
writable, preserving every existing call site's behavior exactly).
`EntityAccessor.get`/`set` enforce the declared mode at compile time, not
just by convention: `get`'s return type is `ref [UntrackedOrigin[mut =
<is-writable>]] T`, so a write-only `get` or a read-only `set` is rejected
during type-checking, with a message naming the specific builder that would
fix it. `SystemContext.run`'s GPU path skips the upload for a write-only
component (via a new `DeviceComponentStorage.ensure_column[T]`, which sizes
the column without transferring anything) and skips the download for a
read-only component.

The load-bearing implementation detail: `mut=<expr>` in a `ref` return
type only accepts a small set of expression forms — direct comptime
parameter access and boolean operators over those fold correctly, but *any*
function call does not, even a fully resolved one with no free parameters,
confirmed by direct probe with progressively simpler repros. The one
exception found is a call already marked `@always_inline("builtin")` in the
standard library, such as `TypeList.contains[T]()`. This is why `_read` and
`_written` are stored as `Components` (backed by `TypeList`) rather than
computed through an ordinary loop-based method: `get`'s return type calls
`Self.filter._written.ComponentTypes.contains[T]()` directly, using that
builtin-inlined stdlib primitive, rather than a hand-written `Filter.writes[T]()`
method, which would not fold in that position no matter how it was written.
`Filter.reads[T]()`/`writes[T]()` still exist as ordinary methods for use
inside function bodies (`comptime assert`, `comptime if`), where an ordinary
method call resolves fine — confirmed working in `SystemContext.run`'s
`comptime if filter.reads[T]():` upload gate and `comptime if
filter.writes[T]():` download gate.

Verified two ways. Compile-time enforcement: a `set` on a `read`-only
component and a `get` on a `write`-only component were each confirmed to
fail to compile, with the intended diagnostic surfacing in the error
(`"declared read-only ... use Filter.write"` and `"declared write-only ...
use set[T]()"` respectively). Performance, on the baseline workload (1M
entities, `Position` read-write, `Velocity`): marking `Velocity` `read`-only
(download skipped) took the steady-state cost from 6.17 ms to 3.82 ms per
call, and additionally marking `Position` `write`-only (upload skipped too,
kernel fully overwrites it) took it to 3.63 ms, both against the same
`include`-both baseline, with output correctness checked over all 1,000,000
entities. The absolute baseline number here is lower than the 9.24 ms
figure elsewhere in this document because it reflects the Phase 1 fixes
already being in place; the relevant comparison is the roughly 40% same-run
reduction from declaring accurate modes, consistent with removing very
close to one whole transfer direction out of two.

Full test suite (`pixi run tests test`, 16 files) passes, including all
three GPU tests.

**Keep component columns resident on the device across frames.** This is the
structural change and the one that actually decides whether the GPU path is
viable. Track, per component column, whether the host copy or the device copy
is authoritative. Upload only when the host copy is dirty, download only when
the host is about to read. Consecutive GPU systems over the same components,
and repeated frames of the same system, then pay the transfer once instead of
once per call. On the baseline workload a 100-frame run goes from 9.24 ms per
frame to roughly 1 ms per frame.

Design notes for residency:

- Invalidation hooks belong on the mutating entry points of `HostStorage`:
  entity creation and removal, component add and remove, and any host-side
  `query` that hands out a mutable component reference. The last one is the
  awkward case, because a mutable query reference is indistinguishable from a
  read at the type level today; the read/write filter work above gives a
  natural place to solve it.
- Structural changes to an archetype, meaning growth, swap-remove, or
  archetype migration, must invalidate the device copy of every column in
  that archetype, since row indices move.
- The row-offset map from Phase 0 becomes the durable description of how
  archetype rows map onto the flat device column, and needs to be rebuilt
  only when archetypes change.

**Stage downloads through a pinned host buffer where a download is still
needed.** Measured for an 8 MB column: `enqueue_copy_to` into a raw `List`
pointer takes 2.40 ms, while `enqueue_copy_to` into a buffer from
`enqueue_create_host_buffer` takes 1.14 ms. The subsequent host-side memcpy
into the archetype column costs roughly 0.4 ms, so the net is about 1.5 ms
against 2.4 ms. Worth doing, but only after the two changes above, since it
optimizes a transfer the others aim to delete.

## Phase 3: launch configuration and pipeline

Modest, cheap, and worth taking once Phase 2 lands.

**Raise the block size.** `BLOCK_SIZE` in `src/larecs/system.mojo:137` is 16.
Apple's SIMD group is 32 wide, so every threadgroup wastes half a SIMD group.
Measured sweep on the baseline kernel:

| block_dim | kernel ms |
| --------- | --------- |
| 8         | 1.62      |
| 16        | 1.57      |
| 32        | 1.71      |
| 64        | 1.74      |
| 128       | 1.47      |
| 256       | 1.43      |

About 10% on a memory-bound kernel, and free. Derive the value from the
device rather than hard-coding it, so a discrete GPU is not stuck with an
Apple-tuned constant.

**Compile kernels ahead of the first launch.** The first `run` call pays
28.6 ms of just-in-time compilation, on the first simulated frame.
`DeviceContext.compile_function` exists and works; the resulting handle can
be passed to `enqueue_function`. Compiling during `Scheduler.initialize` and
caching the handle moves that cost off the frame path.

**Cache the archetype match list per filter.** `_get_archetype_iterator`
builds a `List[Int]` by scanning every archetype, and `run` copies that
iterator once for the length scan plus once per component for upload and
again per component for download. For a two-component filter that is seven
heap allocations per call. The match set changes only when archetypes change,
which is the same invalidation signal Phase 2 already needs.

## Deliberately not doing

**The grid-stride iterator is not a bottleneck.** The obvious suspicion is
that `EntityAccessorIterator` is expensive on the GPU, since it copies the
whole column-pointer array per row and drives control flow through
`raise StopIteration()`. Measured against a hand-written kernel using direct
`global_idx` indexing over identical data: 0.97 ms for the iterator versus
1.04 ms for direct indexing. It compiles away completely. Leave it alone.

**Zero-copy unified memory is not reachable through the current API.**
On Apple silicon the host and GPU share physical memory, so eliminating
transfers entirely looks possible. It is not, through MAX as it stands.
Passing a host buffer's pointer to a kernel produces a launch that silently
does nothing, and reading a `DeviceBuffer`'s pointer from the host crashes
the process. Both probed directly. Revisit if MAX exposes a shared-storage
buffer mode.

## Measurement infrastructure

`benchmark/gpu_system_benchmark.mojo` now exists and is registered in
`run_benchmarks.mojo`. It runs a central-force orbital integration whose
arithmetic intensity is a compile-time parameter: `steps` controls how many
integration steps each entity performs per launch while the bytes moved stay
fixed at 32 per entity, so sweeping `steps` walks one kernel from
memory-bound to compute-bound. Both execution targets run the identical
kernel source through `SystemContext.run`, so the comparison measures the
real API rather than hand-written device code.

Components are `Float32`. Apple GPUs have no double precision, so the
`Float64` `Position` and `Velocity` in `larecs.test_utils` cannot be used on
the device and the benchmark defines its own.

Results at 250,000 entities:

| steps | CPU ms  | GPU ms | GPU speedup | GPU GFLOPS |
| ----- | ------- | ------ | ----------- | ---------- |
| 1     | 0.27    | 2.30   | 0.12x       | 2          |
| 8     | 5.78    | 1.91   | 3.0x        | 19         |
| 64    | 129.0   | 2.21   | 58x         | 131        |
| 512   | 1241.1  | 5.00   | 248x        | 461        |

This changes the picture the memory-bound baseline gave, and it changes what
the phases above are worth.

**The GPU path already wins decisively once there is arithmetic to do.** The
crossover sits between 1 and 8 steps, which is a very low bar: 8 steps is 144
floating point operations per entity. Above it the GPU is faster, and by 512
steps it is 247 times faster. The conclusion from the memory-bound baseline,
that the kernel is slower than the CPU, holds only at the extreme left of
this sweep.

**Transfer cost is a fixed floor of roughly 1.7 ms, not a proportional tax.**
GPU time barely moves from 1 step to 64 steps because the kernel is hiding
under the transfers for that whole range. That floor is exactly what Phases 1
and 2 attack. Removing it would not change the 512-step result much, but it
moves the crossover point sharply left, which is what decides how many real
systems are worth putting on the device at all.

**The CPU side is scalar and single-threaded.** It plateaus at about 1.9
GFLOPS, and its data movement column reads 30 GB/s at 1 step, confirming it
is bandwidth-bound there and reciprocal-square-root-bound afterwards. The
`run` CPU path gives every kernel `thread_count=1` and a stride of 1. There
is a separate and probably large win available in vectorizing or
parallelizing it, which this plan does not cover.

**The GPU reaches about 12% of the M4's single-precision peak.** The step
loop is a serial dependency chain with a reciprocal square root in it, so
there is little instruction-level parallelism to extract per thread. This is
representative of real integration kernels and is not a defect in the launch
configuration.

One measurement caveat: the 1-step GPU entry is noisy, with a spread from
1.91 ms to 3.72 ms against a 2.01 ms maximum at 8 steps. Its mean lands above
the 8-step mean, which is not physically meaningful. The transfer path is the
variable part, which is consistent with everything else here. The CPU entries
vary by roughly 10% run to run; the GPU entries are stable to about 1%.

What the benchmark does not yet cover is the per-phase breakdown from the
baseline table. Measuring that requires reaching inside `run`, so it is
better added alongside the Phase 1 changes than duplicated now against
internals that are about to move.

## Reproducing the numbers

The arithmetic intensity sweep is checked in:

```
pixi run mojo run -I src -I benchmark benchmark/gpu_system_benchmark.mojo
```

Its kernel is verified to agree between the two execution targets. Running
the same integration at 64 steps over 4096 entities on each path and
comparing all 8192 resulting coordinates gives a maximum absolute difference
of 1.19e-07, which is one unit in the last place for `Float32`.

Everything in the baseline table came from standalone scripts run against
this working tree, and is not yet checked in:

- Phase breakdown: replicate `run`'s GPU path with `perf_counter` around each
  phase, three trials, report trials 1 and 2 to exclude just-in-time
  compilation.
- Transfer costs: allocate an 8 MB `DeviceBuffer`, time `enqueue_copy_from`,
  `enqueue_copy_to`, device-to-device copy, `create_buffer_sync`, and
  `enqueue_create_buffer` separately, four trials.
- Block size sweep: fix the data, vary `block_dim` from 8 to 256, five runs
  each, report the minimum.
- Iterator overhead: same data and launch geometry, one kernel using
  `for entity in context` and one using `global_idx` directly, ten runs each,
  report the minimum.
- Launch floor: empty kernel, `grid_dim=1`, `block_dim=1`, fifty runs, report
  the minimum. Measured 0.16 ms.

These should be folded into `benchmark/gpu_system_benchmark.mojo` alongside
the Phase 1 work rather than left as scratch scripts.
