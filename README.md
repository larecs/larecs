# Larecs🌲 – Lightweight archetype-based ECS

Larecs🌲 is a performance-oriented archetype-based ECS for [Mojo](https://www.modular.com/mojo)🔥.
Its architecture is based on the Go ECS [Arche](https://github.com/mlange-42/arche).
Larecs 1.0 is currently in beta, so public APIs may still change before the
stable 1.0.0 release. After that release, public APIs follow semantic
versioning unless they are explicitly marked experimental. See
[compatibility and status](https://larecs.github.io/larecs/reference/compatibility/)
for the experimental features.

## Features

- Archetype storage and compile-time access checks through Mojo parameters
- Native support for [resources](https://larecs.github.io/larecs/guide/shared_resources/) and scheduling
- Systems can run their component-processing kernels on the host or (experimentally) on an accelerator device via `SystemContext.run(..., backend=ExecutionBackend.DEVICE)`
- Tested and benchmarked

Larecs🌲 depends on [Tracy](https://github.com/wolfpld/tracy) via the
[Mojo Tracy bindings](https://github.com/moseschmiedel/mojo-tracy) for its
built-in instrumentation (see [Profiling with Tracy](#profiling-with-tracy)
below) and on [MAX](https://www.modular.com/max) for device execution support;
both are pulled in automatically by Pixi. Beyond Mojo, MAX, and Tracy,
Larecs🌲 has no other external dependencies.

## Installation

The [installation guide](https://larecs.github.io/larecs/start/installation/)
covers the locked Pixi environment, supported platforms, using the source from
your own project, and precompiled packages.

## Usage

Start with [Your first simulation](https://larecs.github.io/larecs/start/first_simulation/),
which moves particles with a system and a kernel. Two further tutorials extend
it with creating and removing particles and with shared configuration. The
complete programs live in [examples/particles](examples/particles). The
[API docs](https://larecs.github.io/larecs/) list every public declaration.

## Contributing

Start with the [contributing guide](CONTRIBUTING.md).
[The design record](docs/design/README.md) collects the ECS
requirements, architecture, and accepted decisions. Read it before you change
behavior; it also explains how to propose or supersede a decision. The
[roadmap](docs/roadmap.md) tracks upcoming work by priority, and the
[changelog](changelog.md) records completed changes. The
[agent guidelines](AGENTS.md) apply to automated contributors.

## Development utilities

### Update Mojo dependency pins

Use the `update-mojo` Pixi task to update every configured Mojo dependency pin
in the repository to the same version. The task runs `scripts/update_mojo.py`,
which updates `mojo` entries in Pixi manifests and `mojo-compiler` entries in
conda recipes.

To update to the newest Mojo version available from the configured channels:

```sh
pixi run update-mojo
```

To choose the Mojo version explicitly:

```sh
pixi run update-mojo 1.0.0b3.dev2026061606
```

By default, the script writes constraints with an exclusive upper bound of
`<2`. Use `--max-version` to choose a different upper bound:

```sh
pixi run update-mojo --max-version 3 1.0.0b3.dev2026061606
```

By default, the script also refreshes the Pixi lockfiles for every configured
Pixi project after editing the pins. To only update the dependency files and
skip relocking, pass `--no-update-lock`:

```sh
pixi run update-mojo --no-update-lock
```

The list of files that may contain Mojo versions is configured at the top of
`scripts/update_mojo.py` in `MOJO_VERSION_FILES`. The channels used for
newest-version discovery are configured in `MOJO_SEARCH_CHANNELS`.

### Profiling with Tracy

Larecs🌲's internals are instrumented with [Tracy](https://github.com/wolfpld/tracy) zones via the [Mojo Tracy bindings](https://github.com/moseschmiedel/mojo-tracy), which is a required build dependency (see `mojo-tracy` in `pixi.toml`). Actually capturing and viewing that instrumentation is optional and only takes effect when the application is compiled with `-DTRACY_ENABLED`.

To enable Tracy profiling, the final application must be compiled with the following flags (see the `profiling` task in `pixi.toml` for reference):

```sh
mojo build -Xlinker -L"${CONDA_PREFIX}/lib" -Xlinker -lmojotracy -DTRACY_ENABLED <your_application_source.mojo>
```

This assumes that `mojo-tracy` was installed via `pixi`.

You can then run the Tracy profiler by calling:

```sh
pixi run tracy-profiler
```

You will need to start the discovery loop of Tracy by clicking "Connect". Then you can execute your compiled application and the profiler will collect data.

The result should look something like this:

![Tracy Profiler](docs/site/assets/img/tracy_profiler.png)

## Limitations

### Type requirements differ by execution target

Any `Copyable & Deinitable` struct can be a component or a resource,
including one that owns heap memory. Kernels add requirements for the
components and resources they access:

| Execution | Accessed components | Accessed resources |
| --- | --- | --- |
| Sequential host (default) | No further requirement | No further requirement |
| Threaded host (experimental) | Pointer-free values with trivial copy, move, and destruction | Read-only pointer-free values, or `DevicePassableResource` adapters |
| Device (experimental) | `TrivialRegisterPassable` | Pointer-free values (read or read-write), or `DevicePassableResource` adapters |

Device execution copies component columns as raw bytes and never runs a
type's copy constructor or destructor, so it requires the
`TrivialRegisterPassable` declaration. Resources are checked by their
representation instead: numeric values, `Bool`, and structs built only from
such values qualify without declaring `TrivialRegisterPassable`. A resource
that owns data, such as a `List`, can still reach threaded and device kernels
through an adapter like `BufferResource`, which exposes a read-only view. A
kernel that accesses an ineligible type fails to compile. See the
[portable resources guide](https://larecs.github.io/larecs/guide/execution/portable_resources/)
for details.

Heap-owning components are a newer and less exercised path than plain-value
components. Prefer plain values unless you need owned data.

## Roadmap

See the [roadmap](docs/roadmap.md) for work planned for the next release,
lower-priority work, and ideas without a release target. Completed work is
recorded in the [changelog](changelog.md).

## License

This project is distributed under the [LGPL3](LICENSE) license.
