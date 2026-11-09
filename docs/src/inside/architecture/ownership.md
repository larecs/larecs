+++
type = "docs"
title = "Execution and ownership"
weight = 1
+++

The {{< api Scheduler >}} owns a {{< api World >}} and registered system
values. Each scheduler phase visits systems in registration order: initialize
once, update once per step, then finalize once. A system receives a
{{< api SystemContext >}} borrowing that world; its kernel receives only the
columns, resources, and captures declared for that invocation.

The diagram separates ownership from temporary access.

![Scheduler owns systems and World; World owns host storage, resource sources, optional device storage and a classifier; contexts borrow those owners.](/images/architecture.svg)

*Solid containment denotes ownership; arrows denote calls and borrowed access.*

We retain host components in `World.storage`, resource sources in
`World.resources`, and optional device allocations in the world. A spatial
classifier is also an owned world value. `KernelContext` contains row count,
column pointers, and binding descriptors; copying it does not copy the world
or extend those allocations' validity beyond the invocation. No context or
row reference may escape its execution boundary.

## One system, multiple kernel invocations

`Move.update` requests one run, but the executor chooses its invocation
granularity. Sequential host execution calls the kernel for each nonempty
matching physical range. Threaded execution can split ranges into chunks.
Device execution packs ranges into one launch. Systems themselves remain
ordered; threaded chunks do not make scheduler systems concurrent.

A side effect outside a kernel's row loop therefore counts invocations,
not simulation steps or entities. The [work mapping](../execution) explains
how row offsets differ between those contexts. The checked particle types
remain `Position.x/y`, `Velocity.dx/dy`, and `Time.delta`; the system is `Move`
and its kernel is `move` in [Your first simulation](../../../start/first_simulation).

## Caller and binding lifetimes

A threaded run prepares contexts and bindings on the caller, retains an
execution guard and structural guard, then joins every worker before releasing
them. The world remains caller-confined: its active flag rejects reentrant
execution, and copying, moving, or destroying an active world aborts.
This flag is a lifecycle check, not a mutex for arbitrary external callers.

Resource bindings retain source leases and invocation-owned views. A device
run retains native staging buffers until queued work completes, publishes
outputs, then releases bindings. See [bindings and transfers](../transfers)
for failure behavior and [structural guards](../iteration) for iteration
ownership.

The thesis architecture predates `SystemContext`, device-copy ownership, and
partition stores. Its mutable-World system signatures do not define today's
API. The adapted diagram describes roles and ownership, not object byte layout.

Implementation: {{< source "scheduler.mojo" >}},
{{< source "world.mojo" >}}, {{< source "system.mojo" >}}.
Evidence: {{< repo "test/scheduler_test.mojo" >}},
{{< repo "test/threaded_execution_test.mojo" >}},
{{< repo "test/resource_adapter_host_test.mojo" >}}.
