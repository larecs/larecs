# Decision 0003: Grid-stride entity iteration

Status: Accepted and implemented for CPU and GPU kernel iteration.

## Context

Giving every GPU thread a row-zero iterator would process the same entity
multiple times. The kernel-facing `KernelContext` and `EntityAccessor` API
must work on CPU and GPU while assigning each matching row to one GPU thread.

## Decision

- A kernel context describes a prepared contiguous row range and its logical
  length. Filtering and packing happen before iteration; the iterator does
  not inspect entity component masks on each step.
- CPU iteration starts at row `0` and advances by `1`.
- GPU thread `global_idx.x` starts at that row and advances by the total
  launched thread count. The iterator stops when its row reaches the context
  length, including in a partial final threadgroup. GPU-specific indices are
  accessed only in GPU-targeted code.
- The launch geometry is derived from the matching row count. A zero-length
  match does not launch a kernel. Compile-time filter access checks remain
  attached to the row accessor on both targets.

## Rationale

For a launch of `N` threads, each row has one remainder modulo `N`, so exactly
one thread visits it. The same iterator abstraction can traverse CPU rows in
order by using a stride of one. Bounds checks make extra threads in the final
group harmless.

## Consequences

Iteration indices are local to the prepared CPU range or packed GPU buffer;
they are not stable world entity IDs or guaranteed to match across targets.
Callers must supply valid component pointers and the correct logical length.
The iterator itself performs no host/device transfer or synchronization.

## Evidence

The implementation is `EntityAccessorIterator` in `src/larecs/iteration.mojo`
and its launch setup in `src/larecs/system.mojo`. The dedicated
`test/grid_stride_iterator_test.mojo` traces row ownership on actual GPU
hardware; system and selection tests exercise the kernel-facing path. See
[ECS-09](../requirements.md).
