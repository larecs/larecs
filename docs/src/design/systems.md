# System Concept Design

This document describes the current direction for Larecs systems. It follows the
prototype in `system_sketch.mojo` and intentionally replaces the earlier design
based on declarative system metadata, dependency graphs, resources, and a
CPU/GPU scheduler.

## Scope

The system API currently has four concepts:

- `System`: a type with an `update` method.
- `Context`: the world-specific context passed to `update`.
- `Filter`: a compile-time include/exclude description used with `Context.run`.
- `KernelContext`: the context passed to a kernel and used to iterate matching
  entities.

The scheduler invokes systems sequentially in registration order. It currently
has only an update phase. Initialization, finalization, dependency inference,
parallel scheduling, runtime system metadata, plugins, and GPU execution are not
part of this API.

## API

### Components and World Shape

The world shape is represented by a compile-time list of component types:

```mojo
@fieldwise_init
struct _World[*WorldTs: ComponentType]:
    comptime component_manager = ComponentManager[*Self.WorldTs]

comptime World = _World[Position, Velocity, Name]
```

`ComponentManager` remains responsible for assigning component IDs. The world
shape is known when the context and scheduler are instantiated.

### Filter

`Filter` stores compile-time component type lists rather than runtime access
metadata:

```mojo
@fieldwise_init
struct Components[*ComponentTypes: ComponentType]:
    pass

@fieldwise_init
struct Filter[
    _include: Components = Components[](),
    _exclude: Components = Components[](),
]:
    comptime include[*ComponentTypes: ComponentType] = Filter[
        Components[
            *TypeList._concat[
                Self._include.ComponentTypes.values,
                ComponentTypes.values,
            ]()
        ](),
        Self._exclude,
    ]

    comptime exclude[*ComponentTypes: ComponentType] = Filter[
        Self._include,
        Components[
            *TypeList._concat[
                Self._exclude.ComponentTypes.values,
                ComponentTypes.values,
            ]()
        ](),
    ]
```

The context exposes an empty filter as its canonical entry point:

```mojo
@fieldwise_init
struct Context[*WorldTs: ComponentType]:
    comptime filter = Filter[]
```

Filters are built by chaining compile-time calls:

```mojo
context.filter.include[Position, Velocity]()
context.filter.include[Name]().exclude[Position, Velocity]()
```

The first form selects entities with both `Position` and `Velocity`. The second
selects entities with `Name` and without `Position` or `Velocity`.

### KernelContext and `run`

Systems define kernels locally and run them through the context:

```mojo
@fieldwise_init
struct Move(System):
    def update[*WorldTs: ComponentType](
        self, context: Context[*WorldTs]
    ):
        def move_entities(kernel_context: KernelContext):
            for entity in kernel_context:
                ref position = entity.get[Position]()
                ref velocity = entity.get[Velocity]()
                position.x += velocity.dx
                position.y += velocity.dy

        context.run[
            context.filter.include[Position, Velocity]()
        ](move_entities)
```

`KernelContext` is the execution context for one kernel invocation. It is
iterable and yields `EntityAccessor` values:

```mojo
@fieldwise_init
struct KernelContext:
    def __iter__(self) -> EntityAccessorIterator:
        return EntityAccessorIterator()
```

The iterator in the prototype is placeholder data. It must eventually iterate
the entities selected by the supplied filter.

`Context.run` currently has the following conceptual signature:

```mojo
def run[
    KernelFunc: def(KernelContext) -> None,
    filter: Filter,
](self, kernel_func: KernelFunc):
    kernel_func(KernelContext())
```

The filter is a compile-time argument. It is not a runtime query object and it
does not carry a mutability flag.

### EntityAccessor

Kernels access entity data through `EntityAccessor`:

```mojo
struct EntityAccessor(Copyable):
    var id: Int

    def get[T: ComponentType](self) -> T:
        ...
```

The prototype returns placeholder component values. The implementation must
replace this with access to the component storage for the current entity.

The intended safety rule is that `get[T]()` is available only when `T` is part
of the kernel's filter. The invalid case in the prototype is:

```mojo
def log_names(kernel_context: KernelContext):
    for entity in kernel_context:
        ref position = entity.get[Position]()  # MUST fail when Position is not included
        ref name = entity.get[Name]()
```

The exact borrow and mutation behavior is still part of the access-control TODO.

## Systems

The system trait is intentionally minimal:

```mojo
trait System(Copyable, Deinitable):
    def update[*WorldTs: ComponentType](
        self, context: Context[*WorldTs]
    ):
        ...
```

Systems do not declare `Queries`, `Reads`, `Writes`, `Resources`, `Phase`,
`Before`, `After`, or GPU kernel metadata. A system's component requirements are
expressed at each `context.run` call through its filter.

Systems may retain ordinary fields for state between updates:

```mojo
@fieldwise_init
struct Counter(System):
    var count: Int

    def update[*WorldTs: ComponentType](
        self, context: Context[*WorldTs]
    ):
        # Persistent fields are available to systems; mutation syntax is still
        # subject to the final System trait signature.
        print(self.count)
```

## Scheduler

The scheduler owns one world and a list of type-erased systems. Each registered
system is paired with a specialized update adapter:

```mojo
@fieldwise_init
struct Scheduler[*WorldComponentTypes: ComponentType]:
    comptime World = _World[*Self.WorldComponentTypes]

    var world: Self.World
    var _systems: List[Tuple[UnsafeBox, Self.FunctionType]]

    def add_system[S: System](mut self, var system: S):
        ...

    def update(mut self, steps: Int = 1) raises:
        ...

    def run(mut self, steps: Int) raises:
        self.update(steps)
```

`update` loops over the requested number of steps, then invokes every system in
registration order. `run` is only a convenience wrapper around `update`.

The scheduler does not currently detect conflicts or construct a dependency
graph. It also does not provide `initialize` or `finalize` callbacks.

## Explicitly Out Of Scope

The following items from the previous design are not part of the current API:

- `Query` values with runtime include/exclude bitmasks.
- Per-query or per-component read/write metadata.
- `System.Queries`, `Reads`, `Writes`, `Resources`, `Before`, or `After` fields.
- Automatic conflict detection and dependency ordering.
- Parallel CPU scheduling.
- Runtime `RegisteredSystem` metadata.
- Plugin composition and compile-time schedule construction.
- GPU systems, `GpuContext`, device buffers, and GPU-specific schedulers.
- GPU dirty tracking, transfer planning, double buffering, and multi-GPU support.
- Scheduler lifecycle methods other than `update`.

These may be reconsidered later, but implementations and documentation should
not assume them as part of this design.

## TODO

The remaining work is the work explicitly identified by `system_sketch.mojo`:

- [ ] Add actual entity and component data storage. Use the current
      `archetype._ComponentTable` as a reference.
- [ ] Add GPU execution only if the project later adopts Modular MAX. The first
      step would be initializing and storing a `DeviceContext`.
- [ ] Restrict `EntityAccessor.get[T]()` to components included by the kernel's
      filter, including the `# MUST fail!` case.
- [ ] Add resource access through `KernelContext`.

The first and third items are required to make the CPU prototype functional.
The GPU item is deliberately not a dependency of the CPU API. Resource access
should be added only after its ownership and borrowing rules are defined.

## Prototype Status

`system_sketch.mojo` demonstrates the intended compile-time filter syntax and
the type-erased scheduler adapter. It does not yet demonstrate real entity
selection or storage access:

- `EntityAccessorIterator` yields five hard-coded entities.
- `EntityAccessor.get[T]()` returns fabricated component values.
- `Context.run` invokes the kernel once without consulting a world.
- `Scheduler` owns a world, but the context does not yet reference its storage.

The prototype should be treated as an API sketch until these limitations are
removed.
