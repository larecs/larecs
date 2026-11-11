+++
type = "docs"
title = "Benchmark index"
weight = 100
prev = false
next = false
[sidebar]
exclude = true
+++

This reference preserves the earlier benchmark page's anchors. Application
measurement starts in [Measure and tune a simulation](../performance/measure).
Implementation methodology, gate operation, and scoped historical evidence
now live under Inside Larecs.

The [report index](../../inside/development/reports) identifies environments
and limitations. The [early selection sample](../../inside/development/reports/selection#early-selection-sample)
and [host-dispatch investigation](https://github.com/larecs/larecs/blob/main/docs/design/research/host-thread-execution.md)
remain accessible; prototype timings do not define current engine performance.

## Benchmark methodology

See [Benchmark methodology](../../inside/development/benchmarks#benchmark-methodology).

## Threaded host execution

See [Threaded host execution](../../inside/development/reports/threaded#threaded-host-execution).

## Synchronization primitives

See [Synchronization primitives](../../inside/development/reports/synchronization#synchronization-primitives).

## Shared host execution comparison

See [Shared host execution comparison](../../inside/development/reports/selection#shared-host-execution-comparison).

## Versus Array of Structs

See [Versus Array of Structs](../../inside/development/reports/aos#versus-array-of-structs).

## PR-to-PR performance checks

See [PR-to-PR performance checks](../../inside/development/regression#pr-to-pr-performance-checks).

## Small spatial benchmarks on every PR

See [Small spatial benchmarks on every PR](../../inside/development/regression#small-spatial-benchmarks-on-every-pr).

## Deferred dirty classification

See [Deferred dirty classification](../../inside/development/reports/dirty_spatial#deferred-dirty-classification).

## Partitioned storage comparison

See [Partitioned storage comparison](../../inside/development/reports/partitions#partitioned-storage-comparison).

### Growable-store comparison on Linux

See [Growable-store comparison on Linux](../../inside/development/reports/partitions#growable-store-comparison-on-linux).

### Historical bounded-block comparison on macOS

See [Historical bounded-block comparison on macOS](../../inside/development/reports/partitions#historical-bounded-block-comparison-on-macos).

## Resource execution

See [Resource execution](../../inside/development/reports/resources#resource-execution).

## Storage range migration

See [Storage range migration](../../inside/development/reports/selection#storage-range-migration).
