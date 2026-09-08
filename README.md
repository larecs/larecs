# Larecs🌲 – Lightweight archetype-based ECS

Larecs🌲 is a performance-oriented archetype-based ECS for [Mojo](https://www.modular.com/mojo)🔥.
Its architecture is based on the Go ECS [Arche](https://github.com/mlange-42/arche). The package is still under construction, so be aware that parts of the API might change in future versions.

## Features

- Clean and simple API
- High performance due to archetypes and Mojo's compile-time programming
- Compile-time checks thanks to usage of parameters
- Native support for [resources](https://mlange-42.github.io/arche/guide/resources/) and scheduling
- Systems can run their component-processing kernels on the CPU or (experimentally) on a GPU accelerator via `SystemContext.run(..., on_gpu=True)`
- Tested and benchmarked
- More features coming soon...

Larecs🌲 depends on [Tracy](https://github.com/wolfpld/tracy) via the
[Mojo Tracy bindings](https://github.com/moseschmiedel/mojo-tracy) for its
built-in instrumentation (see [Profiling with Tracy](#profiling-with-tracy)
below) and on [MAX](https://www.modular.com/max) for GPU execution support;
both are pulled in automatically by Pixi. Beyond Mojo, MAX, and Tracy,
Larecs🌲 has no other external dependencies.

## Installation

This package is written in and for [Mojo](https://docs.modular.com/mojo/manual/get-started)🔥, which needs to be installed in order to compile, test, or use the software. You can build Larecs🌲 as a package as follows:

1. Clone the repository / download the files.
2. Navigate to the `src/` subfolder.
3. Execute `mojo precompile larecs -o larecs.mojoc`.
4. Move the newly created file `larecs.mojoc` to your project's source directory.

### Include source directly for compiler and language server

To access the source while debugging and to adjust the Larecs🌲
source code, you can include it into run commands of your own
projects as follows:

```
mojo run -I "path/to/larecs/src" example.mojo
```

To let VSCode and the language server know of Larecs🌲, include it as follows:

1. Go to VSCode's `File -> Preferences -> Settings` page.
2. Go to the `Extensions -> Mojo` section.
3. Look for the setting `Lsp: Include Dirs`.
4. Click on `add item` and insert the path to the `src/` subdirectory.

## Usage

Refer to the [API docs](https://samufi.github.io/larecs/) for details
on how to use Larecs🌲.

Below there is a simple example covering the most important functionality.
Have a look at the `examples` subdirectory for more elaborate examples.

```mojo
# Import the package
from larecs import World


# Define components
@fieldwise_init
struct Position(Copyable, Movable):
    var x: Float64
    var y: Float64


@fieldwise_init
struct IsStatic(Copyable, Movable):
    pass


@fieldwise_init
struct Velocity(Copyable, Movable):
    var x: Float64
    var y: Float64


# Run the ECS
def main() raises:
    # Create a world, list all components that will / may be used
    var world = World[Position, Velocity, IsStatic]()

    for _ in range(100):
        # Add an entity. The returned value is the
        # entity's ID, which can be used to access the entity later
        var entity = world.storage.add_entity(Position(0, 0), IsStatic())

        # For example, we may want to change the entity's position
        world.storage.get[Position](entity).x = 2

        # Or we may want to replace the IsStatic component
        # of the entity by a Velocity component
        world.storage.replace[IsStatic]().by(Velocity(2, 2), entity=entity)

    # We can query entities with specific components
    for entity in world.storage.query[Position, Velocity]():
        # Get references to specific components
        ref position = entity.get[Position]()
        ref velocity = entity.get[Velocity]()

        position.x += velocity.x
        position.y += velocity.y
```

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

### Component type requirements differ between host and GPU execution

Any `Copyable & Deinitable` struct can be used as a component for CPU
(host-only) execution -- this is no longer restricted to trivial/POD types.

Components accessed by a system that runs its kernel on a GPU
(`SystemContext.run(..., on_gpu=True)`) are subject to a stricter
constraint: GPU transfer moves component columns between host and device
buffers via a raw byte copy that never runs a type's copy constructor or
destructor, so such components must additionally be
`TrivialRegisterPassable` (bitwise-copyable, with no heap-allocated state
and no custom copy/move/destroy logic -- the same requirement applies to
resources read by a GPU kernel). Using a type with heap-allocated memory in
a component accessed on the GPU will corrupt or leak that memory.

Heap-allocated (non-trivial) components for host-only use are permitted by
the type system, but are a comparatively new and lightly-exercised path
compared to trivial components; as with resources, using heap-allocated
data in the ECS should generally be avoided unless you need it.

## Next steps

The goal of Larecs🌲 is to provide a user-friendly ECS with maximal efficiency.
In the near future, Larecs🌲 will take the following steps:

- [x] Add functionality for adding and removing multiple entities at once.
- [ ] Add functionality for setting, adding and removing components of multiple entities at once.
- [x] Improve the documentation
- [x] Add a scheduler for easy setup of ECS.
- [ ] Add built-in support for [event systems](https://mlange-42.github.io/arche/guide/events/index.html).
- [x] Add further options to filter entities (e.g. "does not have component").
- [ ] Add possibilities for parallel execution
- [ ] Improve the API for systems (e.g. allow systems to stop the execution)
- [ ] Add GPU support (in progress) -- systems can already run kernels on an accelerator via `SystemContext.run(..., on_gpu=True)`; this is experimental and still under active development
- [ ] Improve the usability by switching to value unpacking in queries as soon as this is available in Mojo🔥.
- [x] Fix using an inefficient dictionary for first-time archetype lookup.
- [x] Allow the usage of complex types as components, i.e., types that have heap-allocated memory, for host-only (non-GPU) usage.

## License

This project is distributed under the [LGPL3](LICENSE) license.
