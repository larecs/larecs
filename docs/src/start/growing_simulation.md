+++
type = "docs"
title = "Create and remove particles"
weight = 20
+++

In this tutorial you extend the [movement program](../first_simulation) with a
system that creates three moving particles and removes the stationary marker.
You learn how to change which entities exist without affecting the particles
you did not create.

The program keeps `Position`, `Velocity`, `Time`, `move`, and `Move` from the
first tutorial unchanged.

## The program

{{< example file="particles/lifecycle.mojo" full=true >}}

Run it from the repository root:

```sh
pixi run mojo run -I src examples/particles/lifecycle.mojo
```

It prints `Created three particles and removed the stationary marker.`

## Set positions without reading them

New particles start at (9, 9). Before they move, a kernel resets them to the
origin:

{{< example file="particles/lifecycle.mojo" region="write_only" >}}

`Filter().write[Position]()` grants write-only access: the kernel can replace a
position with `set`, but it cannot read one with `get`. A kernel that writes
every value it touches needs no more than this.

## Create the batch in a system

Creating and removing entities changes the world's structure. Do it inside a
system, here in `initialize`, which runs once before the first step:

{{< example file="particles/lifecycle.mojo" region="lifecycle" >}}

{{< api SystemContext.add_entities "context.add_entities(Position(9, 9), count=3)" >}}
creates three particles and returns an `EntitySelection` of exactly those
three. The `with` block binds that selection to `selected`:

1. `selected.add(Velocity(1, 0))` gives the three particles a velocity.
2. `selected.run[reset_position]()` moves them to (0, 0).
3. `selected.run[move]()` advances them once by `Time.delta`, so they start at
   x=0.1.

Each `selected.run` visits only the selected particles, even though `walker`
also has a `Position` and a `Velocity`. While the block is open, the selection
holds a *structural lock*: Larecs rejects any other entity creation, entity
deletion, or component addition or removal in the world. The lock ends when the
block ends, also on an error.

After the block,
{{< api HostStorage.remove_entities "context.world[].storage.remove_entities" >}}
deletes every entity that has a `Position` and no `Velocity`. In this world,
that is `marker`. `Spawn` leaves `update` empty because it does all its work
once.

## Register Spawn before Move

{{< example file="particles/lifecycle.mojo" region="scheduler" >}}

`run` initializes `Spawn` and `Move` in order, then updates them ten times.
`Move` has no initialization, so the three new particles exist before the first
movement step.

## Check the result

{{< example file="particles/lifecycle.mojo" region="check" >}}

`walker` and `climber` end where they did in the first tutorial. Each new
particle starts at x=0.1 and moves ten steps of 0.1, so it ends at x=1.1. The
marker is gone, so five particles have a position.

## Next steps

- Continue with [Share time and configuration](../shared_configuration).
- [Create and remove entities in batches](../../guide/structural_changes)
  covers selections, locks, and deletion in detail.
