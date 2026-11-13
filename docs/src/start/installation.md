+++
type = "docs"
title = "Install Larecs"
weight = 1
aliases = ["/guide/installation/"]
+++

Install the repository's locked Pixi environment and run the first particle
program. Then use Larecs from your own Pixi project, either as source or as a
precompiled package.

Larecs runs on Linux x86-64 and macOS on Apple Silicon. Larecs `1.0.0b1` is a
beta, so its APIs can still change. Pixi installs these dependencies:

- Mojo `>=1.0.0,<1.1.0`
- MAX `>=26.5.0,<27`
- `mojo-tracy >=1.1.0,<2`

It resolves them from the channels `conda-forge`, `https://repo.prefix.dev/max`,
and `https://prefix.dev/tree-d` (for `mojo-tracy`). `pixi.lock` pins the exact
builds.

## Install the locked environment

Install [Pixi](https://pixi.sh/latest/installation/), then run:

```sh
git clone https://github.com/larecs/larecs.git
cd larecs
pixi install --locked
pixi run mojo --version
pixi run mojo run -I src examples/particles/movement.mojo
```

The program prints `All particles reached their expected positions.` and fails
with an assertion error if a particle ends elsewhere. It runs on the host and
needs no accelerator. To reproduce a result later, keep the checkout revision
together with its `pixi.lock`.

Continue with [Your first simulation](../../start/first_simulation), which
explains this program.

## Use the source from your own project

Create a Pixi project next to your clone, add the same dependencies, and pass
the clone's `src` directory as an include path. From the directory that
contains `larecs/`:

```sh
pixi init my-simulation -c conda-forge -c https://repo.prefix.dev/max -c https://prefix.dev/tree-d
cd my-simulation
pixi add "mojo>=1.0.0,<1.1.0" "max>=26.5.0,<27" "mojo-tracy>=1.1.0,<2"
cp ../larecs/examples/particles/movement.mojo main.mojo
pixi run mojo run -I ../larecs/src main.mojo
```

`main.mojo` starts as a copy of the first simulation and prints the same line;
replace it with your own program. Your project resolves its own environment,
so keep its version ranges in line with Larecs's `pixi.toml` when you update
the clone. For completion and diagnostics in your editor, add `../larecs/src`
to the Mojo language server's include directories.

On macOS, the repository's environment runs a script on activation that selects
a macOS SDK the linker accepts; your project does not inherit it. Add it to
your project's `pixi.toml`:

```toml
[target.osx-arm64.activation]
scripts = ["../larecs/scripts/activate_macos_sdk.sh"]
```

## Use a precompiled package

Build the package with the toolchain your application uses. From the repository
root:

```sh
mkdir -p /tmp/larecs-package
pixi run mojo precompile src/larecs -o /tmp/larecs-package/larecs.mojoc
pixi run mojo run -I /tmp/larecs-package examples/particles/movement.mojo
```

Copy `larecs.mojoc` to your project's include directory. Your application's
environment must provide compatible Mojo, MAX, and `mojo-tracy` builds from the
channels above. Rebuild the package after you change the toolchain or the
Larecs revision.

## Troubleshooting

| Symptom | Fix |
| --- | --- |
| Import error for `larecs` | Point `-I` at a directory that contains `larecs/` source or `larecs.mojoc`. |
| Compiler errors after a toolchain upgrade | Restore the locked environment with `pixi install --locked` and rebuild the package. |
| macOS linker error mentioning `arm64e.x1` or `libSystem.tbd` | Install an older macOS SDK. With `SDKROOT` unset, the repository's activation script selects a compatible one; your own project needs the [activation entry above](#use-the-source-from-your-own-project). See the [SDK workaround](https://github.com/larecs/larecs/blob/main/docs/development.md#macos-sdk-linking). |
