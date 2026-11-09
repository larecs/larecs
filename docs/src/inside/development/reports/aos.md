+++
type = "docs"
title = "AoS plotting workflow evidence"
weight = 7
+++

This is a dynamically regenerated comparison, not one fixed historical run.
The workflow records its checkout SHA and resolves Mojo through
`benchmark/plots/pixi.lock`; its `ubuntu-24.04` label does not identify a CPU
or cache size. No numerical speedup is asserted without a selected run's data.
The driver defines iteration calibration and measured work; compiler generation,
world construction, plotting, and dependency setup are outside per-entity loop
timing. Hosted load, changing runner hardware, and artifact retention limit
cross-run interpretation.

## Versus Array of Structs

The publishing-run plots show iteration time per entity for a workload that
adds velocity to position in both dimensions. Historical driver
fields are not the tutorial's API: the checked particle example uses
`Position.x/y` and `Velocity.dx/dy`. See
{{< repo "benchmark/plots/src/aos.mojo" "the plotting driver" >}} for its exact data types.

The benchmark is performed with different amounts of "payload components",
where each of them has two `Float64` fields, just like `Position` and `Velocity`.
Further, the total number of entities is varied from 100 to 1 million.

Plots and raw data are available in the `aos-benchmark` artifact of the
[publishing run](https://github.com/larecs/larecs/actions/workflows/publish.yml)
that produced them. Select the run for the measured checkout SHA; the report
contains no fixed checked-in plot or golden timings.

The documentation workflow (`.github/workflows/publish.yml`) regenerates this
plot for each published commit on a GitHub-hosted `ubuntu-24.04` runner,
using the Mojo version pinned in `benchmark/plots/pixi.lock`. The workflow
does not record the runner's CPU or cache sizes, and the hardware behind that
runner label can change between runs. Read the plot as a comparison on one
machine, not as a prediction for other hardware. Each run keeps the raw
results as its `aos-benchmark` artifact. To measure your own machine, run
`pixi run plots` in `benchmark/plots`.
