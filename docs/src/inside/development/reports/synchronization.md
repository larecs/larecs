+++
type = "docs"
title = "Synchronization measurement protocol"
weight = 3
+++

This record preserves the standalone driver protocol. No hardware, compiler,
run revision, or timing results were recorded with this section, so it makes
no measured performance claim. The driver is available at the documentation
revision through {{< repo "benchmark/synchronization_benchmark.mojo" "its source" >}}.
Current implementation details are in [synchronization internals](../../../architecture/synchronization).

## Synchronization primitives

`benchmark/synchronization_benchmark.mojo` is a focused manual comparison of
100,000 sequential scalar increments using a plain scalar control, direct Mojo
relaxed atomics, Larecs relaxed atomic views, and uncontended write guards. Every
case performs equivalent increments and consumes results. Setup and final exact
total validation are excluded; guard acquisition, payload access, and release
are included. These are isolated uncontended costs, not complete ECS execution,
contention, allocation, transfer, or GPU measurements. No new timing cases are
added to the normal PR performance suite.

Build once without debug information, sanitizers, or tracing, warm the binary,
then run repeated samples without other builds or benchmark jobs:

```sh
pixi run mojo build -I src benchmark/synchronization_benchmark.mojo -o /tmp/larecs-synchronization
/tmp/larecs-synchronization
```

Report compilation time separately from execution and retain hardware/compiler
details with timing claims. Concurrent compound access and exact atomic totals
are correctness checks in `test/synchronization_test.mojo`; contended performance
and complete binding/transfer measurements remain roadmap work.
