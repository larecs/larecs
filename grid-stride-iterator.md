# Grid-stride GPU entity iterator

## Goal

Ensure that a GPU system processes each matching entity exactly once. Before
this work, `system_sketch.mojo` gave every GPU thread an iterator starting at
entity `0`. Each thread therefore walked the complete entity range, causing every
entity to be updated once per launched thread.

The implemented iterator partitions the matching rows across the launched
threads while preserving the same `KernelContext` and `EntityAccessor` API for
CPU and GPU execution.

## Current state

The sketch currently has:

- A dense host and device component storage model.
- A compile-time `Filter` type.
- A filter-specialized `KernelContext` and `EntityAccessor`.
- A logical row length passed to each kernel context.
- A launch configuration derived from the current matching row count.
- A grid-stride iterator for GPU execution.
- A sequential iterator for CPU execution.

The filter currently describes the storage as a whole. Since the prototype has no
per-entity archetype composition, a filter either matches the complete dense row
range or matches no rows. Per-archetype and sparse matching should be added later
through a prepared query/work plan.

## Implemented design

The sketch now uses a grid-stride iterator on the GPU:

```text
thread 0: 0, total_threads, 2 * total_threads, ...
thread 1: 1, total_threads + 1, 2 * total_threads + 1, ...
thread 2: 2, total_threads + 2, 2 * total_threads + 2, ...
```

This gives every thread a disjoint subset of the matching rows and naturally
handles a final partial grid through the existing bounds check.

The CPU path should use the same iterator abstraction with:

```text
start  = 0
stride = 1
```

The GPU path should use:

```text
start  = global_idx.x
stride = total_threads
```

`global_idx` must only be referenced from GPU-targeted code. Use a compile-time
GPU-target check so the host implementation does not attempt to evaluate the GPU
builtin.

## Implementation steps

The following steps are implemented in `system_sketch.mojo`.

### 1. Add execution partition metadata

Extend the filter-specialized `KernelContext` and its device-passable host
counterpart with the total number of launched threads:

```mojo
var thread_count: Int32
```

Set it to `1` for CPU execution. Set it to the one-dimensional launch size for
GPU execution:

```mojo
thread_count = grid_dim * block_size
```

Keep `length` as the number of rows matching the prepared filter.

### 2. Update `EntityAccessorIterator`

Add an iterator stride and initialize the first row according to the execution
backend:

```mojo
comptime if is_gpu():
    self._entity.id = Int32(global_idx.x)
    self._stride = context.thread_count
else:
    self._entity.id = 0
    self._stride = 1
```

`__next__` should:

1. Stop when the current row is greater than or equal to `length`.
2. Copy the current accessor.
3. Advance the iterator by `_stride`.
4. Return the accessor.

Do not use a one-entity special case. The iterator must support multiple rows on
both CPU and GPU.

### 3. Base the launch on matching work

Replace the fixed launch count where possible:

```mojo
grid_dim = ceildiv(matched_count, block_size)
block_dim = block_size
```

The iterator must retain its bounds check because the last block can contain more
threads than matching rows.

For the current dense prototype, `matched_count` is either the storage length or
zero depending on whether the filter matches the initialized columns.

### 4. Keep filtering independent from partitioning

The iterator should only partition a prepared range. It should not inspect
component masks or perform filtering for every entity.

For the current dense storage model:

```text
matching filter  -> base row 0, count length
non-matching     -> count 0
```

For the eventual archetype-backed implementation, introduce a prepared work plan
that contains one of the following:

- contiguous matching ranges `(base_row, row_count)` for homogeneous archetypes;
- a compact device-side row/entity index buffer for sparse or cross-archetype
  queries.

Contiguous ranges are preferred for homogeneous SoA columns because they avoid an
additional index-buffer read. A compact index buffer is appropriate when matching
rows are not contiguous.

### 5. Preserve filter access checks

The compile-time filter parameter should remain attached to `KernelContext` and
`EntityAccessor`. `EntityAccessor.get[T]()` must continue to reject component
access when `T` is not included by the kernel filter.

Filtering and access authorization are separate concerns:

- filtering determines which rows are visited;
- the filter type determines which component accessors are legal.

An invalid filter that both includes and excludes the same component should either
be rejected at compile time or produce zero matching rows.

## Testing plan

The sketch's `main` function asserts rows `0`, `1`, and the final partial-grid
row. The dedicated `test/grid_stride_iterator_test.mojo` trace test also records
the owning thread and atomically counts visits for every row. It uses a small,
intentionally under-subscribed grid so that each thread processes multiple rows.

### CPU regression coverage

Run a CPU kernel over multiple rows and verify that every row is updated exactly
once. This confirms that removing the one-entity placeholder did not change the
CPU behavior.

### GPU duplicate-work regression

Initialize several device positions to `(0, 0)` and velocities to `(1, -1)`. Run one
GPU update and verify that every matching row is exactly:

```text
(1, -1)
```

If all threads still iterate the complete range, the result will be multiplied by
the number of launched threads and this test will fail.

### Partial-grid coverage

Use a row count that is not divisible by `block_size`. Verify that:

- rows below `matched_count` are processed once;
- no row beyond `matched_count` is accessed;
- the final partial block does not cause an out-of-bounds access.

### Filter coverage

Verify at least:

- an include filter visits matching rows;
- an exclude filter that conflicts with the dense storage visits zero rows;
- an include filter for an uninitialized column visits zero rows;
- a kernel attempting to access a non-included component fails at compile time.

### Host/device separation

Continue verifying that CPU updates affect `HostStorage` and GPU updates affect
`DeviceStorage`. Device-to-host copies should remain explicit and should not be
mistaken for mutation of the host columns.

## Acceptance criteria

The implementation is complete when:

- each GPU thread starts at a distinct global row;
- each GPU thread advances by the total launched thread count;
- every matching row is processed at most once per kernel launch;
- all matching rows are processed when the grid is larger than the row count;
- CPU execution still visits every matching row sequentially;
- filter access checks remain compile-time enforced;
- the multi-row, duplicate-work, partial-grid, and filter tests pass;
- `pixi run mojo run -I src system_sketch.mojo` continues to build and run.

## Suggested commit sequence

1. `feat: add grid-stride execution metadata`
   - Add thread-count metadata to kernel contexts.
   - Update the iterator to use GPU global indices and CPU sequential indices.

2. `feat: launch systems for matching row counts`
   - Derive GPU grid dimensions from the prepared matching count.
   - Preserve bounds checks for partial blocks.

3. `test: cover grid-stride system iteration`
   - Add CPU/GPU multi-row tests.
   - Add duplicate-work, partial-grid, and filter regression coverage.
