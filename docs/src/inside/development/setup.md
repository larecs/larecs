+++
type = "docs"
title = "Set up, build, and test"
weight = 1
+++

Use a repository checkout to build Larecs and check a change against its locked
toolchain. The supported Pixi platforms are Linux x86-64 and macOS Apple Silicon.
Application installation has a separate [guide](../../../start/installation).

## Install and smoke-test

From the repository root, install the locked environments and run the checked
movement program:

```sh
pixi install --locked
pixi run mojo --version
pixi run mojo run -I src examples/particles/movement.mojo
```

The program prints `All particles reached their expected positions.` after
asserting the results. The root manifest declares Mojo `>=1.0.0,<1.1.0`, MAX
`>=26.5.0,<27`, and mojo-tracy `>=1.1.0,<2`; `pixi.lock` pins the actual
resolution. Retain the reported compiler build with verification evidence.
The separate scripts environment pins documentation tools.

## Build a package

Precompile the source package, then build an example against that package:

```sh
pixi run mojo precompile src/larecs -o /tmp/larecs.mojoc
pixi run mojo build -I /tmp examples/particles/movement.mojo -o /tmp/larecs-movement
/tmp/larecs-movement
```

This checks package consumption without `-I src`. The final program must
produce the same result as the source smoke run. CI also performs a package
smoke check; generated packages are disposable build outputs.

## Run focused checks, then the suite

For a storage-lifecycle change, run the focused test before the full suite:

```sh
pixi run tests test/host_storage_lifecycle_test.mojo
pixi run tests test
pixi run test-resource-compile-failures
```

The test wrapper precompiles Larecs and uses assertions, debug information,
tracing linkage, and AddressSanitizer unless a file opts out. A full directory
run also executes compile-contract checks and bounded core/spatial performance
checks. Focused files trigger their associated contracts but omit performance
checks. The resource compile-failure fixture task is a separate CI step.
Use [test and hardware coverage](../checks) to select the right checks and
interpret device skips. Optimized performance measurements need separate
untraced, unsanitized binaries.

## Resolve platform failures

| Symptom | Action |
| --- | --- |
| Metal compiler crashes compiling a GPU iterator with `-g` | Add `# SKIP_DEBUG` to every GPU-launching test. Keep the actual GPU path; see the {{< repo "docs/development.md#metal-debug-info" "Metal compiler workaround" >}}. |
| `libSystem.tbd` reports unknown `arm64e.x1` architecture | Install an older compatible macOS SDK and leave `SDKROOT` unset so Pixi activation can choose it. An explicit `SDKROOT` is respected; see the {{< repo "docs/development.md#macos-sdk-linking" "SDK workaround" >}}. |
| A focused test needs a custom invocation | `pixi run tests --no-precompile test/<filename>.mojo` omits package precompilation; keep include/linker settings consistent with the wrapper. |

The canonical {{< repo "docs/development.md#coding-standards" "coding standards" >}}
and {{< repo "test/run_tests.sh" "test wrapper" >}} remain at their repository
paths. [Build documentation](../documentation) when examples or contracts change.
