![CodeQL](https://github.com/larecs/larecs/workflows/CodeQL/badge.svg)

# Larecs🌲 – Lightweight archetype-based ECS

Larecs🌲 is a performance-oriented archetype-based ECS for [Mojo](https://www.modular.com/mojo)🔥.
Its architecture is based on the Go ECS [Arche](https://github.com/mlange-42/arche). The package is still under construction, so be aware that parts of the API might change in future versions.

## Features

- Clean and simple API
- High performance due to archetypes and Mojo's compile-time programming
- Support for SIMD via a [`vectorize`](https://docs.modular.com/mojo/stdlib/algorithm/functional/vectorize/)-like syntax
- Compile-time checks thanks to usage of parameters
- Native support for [resources](https://mlange-42.github.io/arche/guide/resources/) and scheduling.
- Tested and benchmarked
- No external dependencies
- Optional profiling with [Tracy](https://github.com/wolfpld/tracy)
- More features coming soon...

## Installation

This package is written in and for [Mojo](https://docs.modular.com/mojo/manual/get-started)🔥, which needs to be installed in order to compile, test, or use the software. You can build Larecs🌲 as a package as follows:

1. Clone the repository / download the files.
2. Navigate to the `src/` subfolder.
3. Execute `mojo package larecs`.
4. Move the newly created file `larecs.mojopkg` to your project's source directory.

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

```python
# Import the package
from larecs import World, Resources


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
fn main() raises:
    # Create a world, list all components that will / may be used
    world = World[Position, Velocity, IsStatic]()

    for _ in range(100):
        # Add an entity. The returned value is the
        # entity's ID, which can be used to access the entity later
        entity = world.add_entity(Position(0, 0), IsStatic())

        # For example, we may want to change the entity's position
        world.get[Position](entity).x = 2

        # Or we may want to replace the IsStatic component
        # of the entity by a Velocity component
        world.replace[IsStatic]().by(Velocity(2, 2), entity=entity)

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

The script only updates dependency files by default. To also refresh the Pixi
lockfiles for configured Pixi projects, pass `--update-locks`:

```sh
pixi run update-mojo --update-locks
```

The list of files that may contain Mojo versions is configured at the top of
`scripts/update_mojo.py` in `MOJO_VERSION_FILES`. The channels used for
newest-version discovery are configured in `MOJO_SEARCH_CHANNELS`.

### Profiling with Tracy

Larecs🌲 supports optional profiling with [Tracy](https://github.com/wolfpld/tracy) enabled by the [Mojo Tracy bindings](https://github.com/moseschmiedel/mojo-tracy).

To enable Tracy profiling, the final application must be compiled with the following flags (see the `profiling` task in `pixi.toml` for reference):

```sh
mojo build -XLinker -L"${CONDA_PREFIX}/lib" -XLinker -lmojotracy -DTRACY_ENABLED <your_application_source.mojo>
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

### Only trivial types can be components

Larecs🌲 currently only supports trivial types as components, i.e., structs
that have a fixed size in memory and can be copied and moved via a
simple memory copy operation. Using types with heap-allocated memory will
result in memory leaks and / or undefined behaviour, and as of now there is no
good way to enforce that only compatible types are used.
Hence, it is up to the users to take care of this.

Note that using types with heap-allocated memory is typically a bad idea for
ECS and should be avoided anyway.

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
- [ ] Add GPU support
- [ ] Improve the usability by switching to value unpacking in queries as soon as this is available in Mojo🔥.
- [x] Fix using an inefficient dictionary for first-time archetype lookup.
- [ ] Allow the usage of complex types as components, i.e., types that have heap-allocated memory.

## License

This project is distributed under the [LGPL3](LICENSE) license.
