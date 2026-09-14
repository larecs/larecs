+++
type = "docs"
title = "Systems and the scheduler"
weight = 60
+++

A key feature of entity-component systems is that
operations on the entities are organized in systems,
which operate independently from one another and can
be added or removed as required.

## Systems

Systems are the principal way to mutate the state of the ECS. Application
logic that creates or removes entities, changes components, or updates
resources should generally live in a system, where the scheduler can run it
in a defined order with access to the appropriate context.

Systems are structs implementing the {{< api System >}} trait, so they can
retain state between calls. A system implements
{{< api System.update update >}}, which is called at every step of the ECS run.
It can also override the default no-op
{{< api System.initialize initialize >}} and
{{< api System.finalize finalize >}} methods, which run before and after the
update loop.

Each lifecycle method receives a {{< api SystemContext >}}. Its `world` field
provides access to entities, components, and resources for individual or
structural changes. For component processing across every entity matching a
filter, the system calls {{< api SystemContext.run >}} with a kernel. A kernel
is a function that receives a {{< api KernelContext >}}; it is not itself a
system and is not registered with the scheduler.

```mojo {doctest="guide_systems_scheduler" global=true}
from larecs import (
    World,
    System,
    SystemContext,
    KernelContext,
    Filter,
    Resources,
    ResourceType,
)

@fieldwise_init
struct Time(ResourceType, TrivialRegisterPassable):
    var delta: Float64

# This kernel writes Position and reads Velocity for every matching entity.
# Move.update invokes it through the system's SystemContext below.
comptime move_resources = Resources[Time]()

def move_entities(
    context: KernelContext[
        Filter().include[Position].read[Velocity](), move_resources
    ]
):
    ref time = context.resources.get[Time]()
    for entity in context:
        ref pos = entity.get[Position]()
        ref vel = entity.get[Velocity]()
        pos.x += vel.dx * time.delta
        pos.y += vel.dy * time.delta

@fieldwise_init
struct Move(System):

    # This is executed once at the beginning
    def initialize(mut self, mut context: SystemContext[...]) raises:
        # We do not need to do anything here
        pass

    # This is executed in each step
    def update(mut self, mut context: SystemContext[...]) raises:
        # Move all entities with a position and velocity
        context.run[move_entities]()

    # This is executed at the end
    def finalize(mut self, mut context: SystemContext[...]) raises:
        # We do not need to do anything here
        pass
```

> [!Note]
> `SystemContext[...]` uses `...` to let the compiler infer the context's
> world origin and component types from where the system is used, rather
> than spelling them out. The `world` field is a `Pointer`, so it must be
> dereferenced (`context.world[]`) to reach the world itself.

## Scheduler

The {{< api Scheduler >}} is responsible for executing the systems
in the correct order. A `Scheduler` contains a {{< api World >}} instance
and a list of systems. The scheduler has
{{< api Scheduler.initialize initialize >}},
{{< api Scheduler.update update >}}, and {{< api Scheduler.finalize finalize >}}
methods, which call the respective functions of all
registered systems in the order they are added to the scheduler.
In addition, the scheduler has a {{< api Scheduler.run run >}}
method, which initializes the systems, calls their `update` methods a requested
number of times, and then finalizes them.

To construct an example of a scheduler, let us define
further systems for adding entities and logging their positions.

```mojo {doctest="guide_systems_scheduler" global=true hide=true}
@fieldwise_init
struct Position(Movable, Copyable, TrivialRegisterPassable):
    var x: Float64
    var y: Float64

@fieldwise_init
struct Velocity(Movable, Copyable, TrivialRegisterPassable):
    var dx: Float64
    var dy: Float64
```

```mojo {doctest="guide_systems_scheduler" global=true}
@fieldwise_init
struct AddMovers[count: Int](System):

    # This is executed once at the beginning
    def initialize(mut self, mut context: SystemContext[...]) raises:
        _ = context.world[].storage.add_entities(
            Position(0, 0), Velocity(1, 0), count=Self.count
        )

    # This is executed in each step
    def update(mut self, mut context: SystemContext[...]) raises:
        # We do not need to do anything here
        pass

    # This is executed at the end
    def finalize(mut self, mut context: SystemContext[...]) raises:
        # We do not need to do anything here
        pass

@fieldwise_init
struct Logger[interval: Int](System):

    var _logging_step: Int

    def __init__(out self):
        self._logging_step = 0

    def _print_positions(self, mut context: SystemContext[...]) raises:
        for entity in context.world[].storage.query[Filter().include[Position, Velocity]()]():
            ref pos = entity.get[Position]()
            print("(", pos.x, ",", pos.y, ")")

    # This is executed once at the beginning
    def initialize(mut self, mut context: SystemContext[...]) raises:
        print("Starting with", len(context.world[].storage.query[Filter().include[Position, Velocity]()]()),
              "moving entities.")

    # This is executed in each step
    def update(mut self, mut context: SystemContext[...]) raises:
        if not self._logging_step % self.interval:
            print("Current Mover positions:")
            self._print_positions(context)
        self._logging_step += 1

    # This is executed at the end
    def finalize(mut self, mut context: SystemContext[...]) raises:
        print("Final positions:")
        self._print_positions(context)
```

Now we can create a scheduler and add the systems to it.
Import the scheduler struct:

```mojo {doctest="guide_systems_scheduler" global=true}
from larecs import Scheduler
```

Create and run the scheduler:

```mojo {doctest="guide_systems_scheduler" global=true}
def main() raises:
    # Create a scheduler
    var scheduler = Scheduler[Position, Velocity]()

    # Add every resource required by a kernel before it can run
    scheduler.world.resources.add(Time(1.0))

    # Add the systems to the scheduler
    scheduler.add_system(AddMovers[10]())
    scheduler.add_system(Move())
    scheduler.add_system(Logger[2]())

    # Run the scheduler for 10 steps
    scheduler.run(10)
```

## Resources in kernels

Systems may access the world's resource storage directly through
`context.world[].resources`, for example when adding a resource during
`initialize`. The example above adds `Time` before `Move` runs and declares it
in the kernel's `Resources[Time]()` list. See
[Resources](../resources#using-resources-in-kernels) for the complete kernel
API, missing-resource behavior, mutation semantics, and runnable examples.

## GPU execution

The `SystemContext.run` call used by `Move` executes its kernel on the CPU by
default. Pass `on_gpu=True` to run a compatible kernel on an accelerator. The
same kernel function works on both targets unchanged; see the
{{< api SystemContext.run >}} and {{< api KernelContext >}} API docs for
details. GPU execution requires an available accelerator and the corresponding
Mojo GPU toolchain. On systems without one, `on_gpu=True` kernels fall back to
CPU execution.

Required resources use the same `context.resources.get[T]()` API on the GPU.
Resource transfer constraints, shared-write safety, and the non-capturing
kernel requirement are covered in
[Resources](../resources#using-resources-in-kernels).
