+++
type = "docs"
title = "Execution"
weight = 7
+++

Choose where a particle kernel runs and how it receives data. Complete
[Your first simulation](../../start/first_simulation) and
[Share time and configuration](../../start/shared_configuration) first. Each
guide has its own complete program; the order below follows their
dependencies, so later guides build on earlier ones.

| Task | Result |
| --- | --- |
| [Run threaded host kernels](threaded) | Split one kernel call into chunks that run on host worker threads. |
| [Execute on a device](device) | Run the same kernel on an accelerator and compare it with the host. |
| [Pass local values to kernels](captures) | Give a kernel a step-local value and get a result back, on the host or a device. |
| [Use portable resources](portable_resources) | Read an owning collection through a kernel view on either target. |
| [Reuse unchanged device copies](copy_reuse) | Skip uploads of data that has not changed since the last device call. |
| [Coordinate shared writes](shared_writes) | Compute one shared result from many invocations without a data race. |

## The portable particle model

Every program in this section uses the same variant of the particle types:

{{< example file="particles/device.mojo" region="model" >}}

It differs from the first simulation in two ways, both needed for device
execution:

- The fields are `Float32`, because Apple GPUs have no 64-bit floating-point
  arithmetic. The host runs use `Float32` too, so host and device compute the
  same values.
- `Position` and `Velocity` conform to `TrivialRegisterPassable`. Device
  execution requires it of every component a kernel accesses, because Larecs
  copies those components to the device byte by byte.

Threaded host execution needs neither change. It accepts any component whose
fields hold no pointers and own no memory, such as the `Float64` types of the
first simulation, with or without the trait. `Time` needs no trait on any
target, because Larecs checks resources by their fields. The guides keep one
model so that each program can switch targets without changing its types.

[Compatibility and status](../../reference/compatibility) lists what each target
accepts and the limits that apply everywhere.
[Errors and migration](../../reference/errors) indexes common failures.
[Work mapping](../../inside/architecture/execution) explains how sequential,
threaded, and device execution divide rows.
