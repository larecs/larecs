+++
type = "docs"
title = "Installation"
weight = 1
+++

Use the repository's locked Pixi environment to run your first host simulation.
The manifest supports Linux x86-64 and macOS Apple Silicon; it requires Mojo
`>=1.0.0,<1.1.0`, MAX `>=26.5.0,<27`, and `mojo-tracy >=1.1.0,<2`.
The manifest uses `conda-forge`, `https://repo.prefix.dev/max`, and
`https://prefix.dev/tree-d` (for `mojo-tracy`). `pixi.lock` selects the exact builds.
Larecs is currently a development beta (`1.0.0b1`); APIs can change.

## Install and verify the pinned environment

Install [Pixi](https://pixi.sh/latest/installation/), then run:

```sh
git clone https://github.com/larecs/larecs.git
cd larecs
pixi install --locked
pixi run mojo --version
pixi run mojo run -I src examples/particles/movement.mojo
```

Keep the checkout revision and its `pixi.lock` together for reproducibility.
The program prints `All particles reached their expected positions.` Its
assertions verify the result. Host execution needs no accelerator.
Continue with [Your first simulation](../../start/first_simulation).

## Run from an external project using source

Keep the compatible toolchain by invoking the repository's environment, and
supply an absolute include path. From the repository root:

```sh
larecs_root="$PWD"
particle_project="$(mktemp -d)"
cp examples/particles/movement.mojo "$particle_project/main.mojo"
cd "$particle_project"
pixi run --manifest-path "$larecs_root/pixi.toml" mojo run -I "$larecs_root/src" "$particle_project/main.mojo"
```

This runs the same asserted simulation with the program outside the repository.
In your editor, add the absolute `src` directory to Mojo's LSP include directories.

## Use a precompiled package

Build the package with the same toolchain used by your application. From the
repository root:

```sh
mkdir -p /tmp/larecs-package
pixi run mojo precompile src/larecs -o /tmp/larecs-package/larecs.mojoc
pixi run mojo run -I /tmp/larecs-package examples/particles/movement.mojo
```

You can copy that `larecs.mojoc` to your project's include directory. Your
application environment must also provide compatible Mojo, MAX, and `mojo-tracy`
from the channels listed above.
Rebuild it after changing the toolchain or Larecs revision. These instructions
use a locally built package; they do not require a published package channel.

## Troubleshooting

An import error for `larecs` means the include directory must contain either
`larecs/` source or `larecs.mojoc`. Compiler errors after a toolchain upgrade
mean you should restore the checkout's locked environment and rebuild the package.
On macOS, an `arm64e.x1` or `libSystem.tbd` linker error requires an older installed
SDK; the repository activation script selects a compatible SDK when `SDKROOT`
is unset. See the [SDK workaround](https://github.com/larecs/larecs/blob/main/docs/development.md#macos-sdk-linking).
