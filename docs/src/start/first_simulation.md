+++
type = "docs"
title = "Your first simulation"
weight = 10
+++

In this tutorial you build a program that moves particles across a plane and
checks where they end up. You define the particle data, write the movement
logic once, and let Larecs apply it to every particle that can move.

You need a working Mojo installation and the Larecs source, as described in
[Installation](../../start/installation). The tutorial assumes you can read
basic Mojo: structs, functions, and `var` declarations.

## The program

The complete program is a single file. You can open it now, or read it piece
by piece below.

{{< example file="particles/movement.mojo" full=true >}}

Run it from the repository root:

```sh
pixi run mojo run -I src examples/particles/movement.mojo
```

It prints `All particles reached their expected positions.`

## Describe particles with components

An *entity* is a particle's identity: a handle with no data of its own.
*Components* are the data you attach to an entity. A particle has a position
and a velocity:

{{< example file="particles/movement.mojo" region="components" >}}

Components are ordinary structs. `@fieldwise_init` generates the constructor
`Position(x, y)`, and `Copyable` and `Movable` let Larecs store and move the
values. Each component type appears at most once per entity.

## Share the step length as a resource

Every particle moves for the same amount of simulated time per step. Data that
exists once for the whole simulation, rather than once per particle, is a
*resource*:

{{< example file="particles/movement.mojo" region="time" >}}

## Write the movement kernel

A *kernel* is a function that Larecs calls with a {{< api KernelContext >}}.
Iterating the context visits every particle that matches the kernel's filter:

{{< example file="particles/movement.mojo" region="kernel" >}}

`move_filter` declares two things at compile time:

- **Which particles match.** Only entities with both `Position` and `Velocity`
  are visited.
- **How the kernel accesses each component.** `include[Position]()` grants
  read-write access, and `read[Velocity]()` grants read-only access. Larecs
  rejects writes to `Velocity` at compile time.

`move_resources` declares that the kernel reads `Time`. A kernel can access
only the resources it declares.

The trailing `()` after each step of the filter turns the description into a
value. `ref` binds a reference to the stored component, so assigning to
`position.x` changes the particle in place.

## Run the kernel from a system

A *system* holds application logic and runs once per simulation step. `Move`
runs the kernel:

{{< example file="particles/movement.mojo" region="system" >}}

`Move` implements the {{< api System >}} trait. The scheduler calls its
`update` method once per step and passes a {{< api SystemContext >}}.
`SystemContext[...]` lets the compiler infer the context's parameters from the
world it belongs to. {{< api SystemContext.run "context.run[move]()" >}} calls
`move` for the particles that match `move_filter`.

`System` also offers `initialize` and `finalize`, which run once before the
first and after the last step. `Move` keeps their default empty
implementations.

## Create the world

A {{< api World >}} stores all entities, components, and resources. Its
parameters list every component type the world can hold:

{{< example file="particles/movement.mojo" region="world" >}}

`add_entity` creates an entity with the given components and returns its
{{< api Entity >}} handle. `walker` and `climber` have both components. `marker`
has only a position, so `move` never visits it.

## Run the scheduler

The {{< api Scheduler >}} owns the world and calls your systems in the order
you add them:

{{< example file="particles/movement.mojo" region="scheduler" >}}

`Scheduler[Position, Velocity]` repeats the world's component types because the
scheduler's type must match the world it owns. `world^` transfers ownership of
the world to the scheduler; `world` is no longer usable afterwards.
`run(steps=10)` initializes every system, calls each `update` ten times, and
finalizes every system.

## Check the result

After ten steps of `0.1`, `walker` has moved one unit along x and `climber` two
units along y. `marker` has not moved:

{{< example file="particles/movement.mojo" region="check" >}}

Read components back through `scheduler.world.storage` with the entity handles
from `add_entity`. `assert_almost_equal` tolerates the rounding error of
adding `0.1` ten times.

## What happened in each step

![Diagram of one run of the move kernel. Larecs stores walker and climber
together because they have the same components, and marker separately. The
filter matches only the Position and Velocity store, so Larecs creates one
KernelContext for it and calls move once on the host thread. The context visits
walker and then climber. The Position-only store gets no context and no
call.](/images/host-execution.svg)

*One `context.run[move]()` call. Larecs keeps entities with the same set of
components together in one store. The filter decides which stores `move` sees:
the store with `Position` and `Velocity` gets a `KernelContext`, and `move`
visits its rows in order. The store without `Velocity` is skipped entirely.*

On the host, `context.run[move]()` calls `move` once for each non-empty store
that matches the filter, one after the other, and returns when all calls have
finished. Write kernels so that each call handles only the rows of its own
context; a world with more component combinations has more stores and
therefore more calls per step.

## Next steps

Continue with [Create and remove particles](../growing_simulation), then
[Share time and configuration](../shared_configuration).

- {{< api SystemContext.run >}} lists every way to run a kernel, including the
  errors it raises.
- [Inspect entities outside a kernel](../../guide/systems_kernels#inspect-entities-outside-a-kernel)
  shows how to read entities with a query.
- [Share values with resources](../../guide/shared_resources) covers adding,
  reading, and changing resources.
