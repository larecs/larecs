+++
type = "docs"
title = "Install Larecs"
weight = 1
+++

Install the repository's locked Pixi environment and run the first particle
program. Then use Larecs from your own project, either as source or as a
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

Run your program with the repository's environment and pass the absolute path
of `src` as an include directory. From the repository root:

```sh
larecs_root="$PWD"
particle_project="$(mktemp -d)"
cp examples/particles/movement.mojo "$particle_project/main.mojo"
cd "$particle_project"
pixi run --manifest-path "$larecs_root/pixi.toml" mojo run -I "$larecs_root/src" "$particle_project/main.mojo"
```

This runs the same program from a directory outside the repository. For
completion and diagnostics in your editor, add the same `src` path to the Mojo
language server's include directories.

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
| macOS linker error mentioning `arm64e.x1` or `libSystem.tbd` | Install an older macOS SDK. With `SDKROOT` unset, the repository's activation script selects a compatible one. See the [SDK workaround](https://github.com/larecs/larecs/blob/main/docs/development.md#macos-sdk-linking). |
