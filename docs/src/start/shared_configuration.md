+++
type = "docs"
title = "Share time and configuration"
weight = 30
+++

Use one configuration value to control the step length during updates. This
complete program also includes [creation and removal](../growing_simulation).

```sh
pixi run mojo run -I src examples/particles/configuration.mojo
```

{{< example file="particles/configuration.mojo" full=true >}}

## Set time before movement

{{< example file="particles/configuration.mojo" region="configuration" >}}

`Configuration` holds one shared step length. `ConfigureTime.update` reads it
and updates `Time.delta` through {{< api ResourceStorage.get >}}.

{{< example file="particles/configuration.mojo" region="world" >}}
{{< example file="particles/configuration.mojo" region="scheduler" >}}

{{< api Scheduler >}} updates systems in registration order: `ConfigureTime`
runs before `Move`, so each of the ten updates uses `0.25`. Before those updates,
`Spawn.initialize` moves the new particles once with the initial `Time.delta`
of `0.1`. They finish at x=0.1 + 10×0.25 = 2.6; walker starts at zero and
finishes at x=2.5.

{{< example file="particles/configuration.mojo" region="check" >}}

The program prints `Configured time moved walker to x=2.5 and climber to y=5.`
See [Resources](../../guide/shared_resources) for permissions and missing values.
