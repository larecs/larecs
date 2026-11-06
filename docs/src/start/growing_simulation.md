+++
type = "docs"
title = "Create and remove particles"
weight = 20
+++

Extend [movement](../first_simulation) with a batch of three moving particles
and remove the stationary marker. Run the complete program from the repository:

```sh
pixi run mojo run -I src examples/particles/lifecycle.mojo
```

{{< example file="particles/lifecycle.mojo" full=true >}}

## Create only the new particles

{{< example file="particles/lifecycle.mojo" region="lifecycle" >}}

`Spawn.initialize` uses {{< api SystemContext.add_entities >}} to create three
positions. Its [EntitySelection](https://github.com/larecs/larecs/blob/d7629334a68981f32c0399e5e4be5496256b7ae5/src/larecs/system.mojo#L568) contains exactly those new entities,
even when other particles have the same components. `selected.add` attaches
velocity, then `selected.run` moves only those three particles by `0.1`.
The scope releases the structural lock before
{{< api HostStorage.remove_entities >}} deletes positions without velocity.

## Schedule creation before movement

{{< example file="particles/lifecycle.mojo" region="scheduler" >}}

Initialization runs before the ten updates. The original walker still reaches
x=1; the stationary marker is gone and five positions remain:

{{< example file="particles/lifecycle.mojo" region="check" >}}

The program prints `Created three particles and removed the stationary marker.`
Continue with [shared configuration](../shared_configuration), or use the
[Structural changes guide](../../guide/structural_changes) for mutation rules.
