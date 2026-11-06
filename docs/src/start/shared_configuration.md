+++
type = "docs"
title = "Share time and configuration"
weight = 30
+++

In this tutorial you extend the [creation program](../growing_simulation) so
that a configuration value controls the step length. You add a second resource
and a system that copies it into `Time` before every movement step.

## The program

{{< example file="particles/configuration.mojo" full=true >}}

Run it from the repository root:

```sh
pixi run mojo run -I src examples/particles/configuration.mojo
```

It prints `Configured time moved walker to x=2.5 and climber to y=5.`

## Add a configuration resource and a system that applies it

{{< example file="particles/configuration.mojo" region="configuration" >}}

`Configuration` is a resource like `Time`: one value for the whole world.
`ConfigureTime.update` reads it through `context.world[].resources` and assigns
its `delta` to `Time.delta`.
{{< api ResourceStorage.get >}} returns a reference, so the assignment changes
the stored `Time` in place.

## Add both resources to the world

{{< example file="particles/configuration.mojo" region="world" >}}

`Time` starts at `0.1` and `Configuration` holds `0.25`. One
{{< api ResourceStorage.add >}} call adds both.

## Order the systems

{{< example file="particles/configuration.mojo" region="scheduler" >}}

The {{< api Scheduler >}} updates systems in the order you add them.
`ConfigureTime` comes before `Move`, so every movement step uses `0.25`.
If you add `ConfigureTime` after `Move`, the first step still uses `0.1`.

`Spawn.initialize` runs before any update. It moves the new particles once with
the initial `Time.delta` of `0.1`.

## Check the result

{{< example file="particles/configuration.mojo" region="check" >}}

`walker` moves ten steps of 0.25 and ends at x=2.5; `climber` ends at y=5. The
new particles start at x=0.1 and end at x=0.1 + 10 × 0.25 = 2.6.

## Next steps

- [Share values with resources](../../guide/shared_resources) covers resource
  permissions and what happens when a resource is missing.
- [Update entities with systems and kernels](../../guide/systems_kernels)
  covers filters, system order, and inspection.
