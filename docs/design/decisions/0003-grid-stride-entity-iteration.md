---
id: "0003"
title: "Grid-stride entity iteration"
status: accepted
---

# Decision 0003: Grid-stride entity iteration

## Context

Giving every GPU thread a row-zero iterator would process the same entity
multiple times. The kernel-facing `KernelContext` and `EntityAccessor` API
must work on host and device while assigning each matching row to one GPU thread.

## Decision

- A kernel context describes a prepared contiguous row range and its logical
  length. Filtering and packing happen before iteration; the iterator does
  not inspect entity component masks on each step.
- Host iteration starts at row `0` and advances by `1`.
- GPU thread `global_idx.x` starts at that row and advances by the total
  launched thread count. The iterator stops when its row reaches the context
  length, including in a partial final threadgroup. GPU-specific indices are
  accessed only in GPU-targeted code.
- The launch geometry is derived from the matching row count. A zero-length
  match does not launch a kernel. Compile-time filter access checks remain
  attached to the row accessor on both targets.
- Blocks have `BLOCK_SIZE = 256` threads, a multiple of every common SIMD
  width (32 on NVIDIA and Apple, 64 on AMD). The grid launches one thread per
  row but at most one wave of blocks the device can keep resident
  (multiprocessor count times `BLOCK_SIZE` blocks per multiprocessor); above
  that, threads cover several rows through the grid-stride loop. The cap is
  disabled if the device does not report the required attributes.

## Rationale

For a launch of `N` threads, each row has one remainder modulo `N`, so exactly
one thread visits it. The same iterator abstraction can traverse host rows in
order by using a stride of one. Bounds checks make extra threads in the final
group harmless.

Smaller blocks leave warps partially empty and hit the per-multiprocessor
block limit long before the thread limit, reducing occupancy; a block-size
sweep on Apple hardware measured 256 as fastest (1.43 ms against 1.57 ms at
the previous 16). Grids beyond one resident wave only queue further blocks,
so capping them reuses resident threads instead. Lanes of a warp still visit
consecutive rows in every iteration, so column accesses stay coalesced.

## Consequences

Iteration indices are local to the prepared host range or packed device buffer;
they are not stable world entity IDs or guaranteed to match across targets.
Callers must supply valid component pointers and the correct logical length.
The iterator itself performs no host/device transfer or synchronization.

## Evidence

The implementation is `EntityAccessorIterator` in `src/larecs/iteration.mojo`
and its launch setup in `src/larecs/system.mojo` and
`src/larecs/gpu_launch.mojo`. `test/launch_geometry_test.mojo` checks grid
sizing and capping on the host. The dedicated
`test/grid_stride_iterator_test.mojo` traces row ownership on actual GPU
hardware; system and selection tests exercise the kernel-facing path. See
[ECS-09](../requirements.md).
