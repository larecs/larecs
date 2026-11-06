+++
type = "docs"
title = "Share time and configuration"
weight = 30
+++

Use one configuration value to control every particle's step length. This stage
runs independently of [creation and removal](../growing_simulation).

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
runs before `Move`, so movement reads `0.25` on every step.

{{< example file="particles/configuration.mojo" region="check" >}}

The program prints `Configured time moved walker to x=2.5 and climber to y=5.`
See [Resources](../../guide/shared_resources) for permissions and missing values.
