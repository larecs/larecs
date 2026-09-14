+++
type = "docs"
title = "Vectorization"
weight = 70
draft = true
+++

Mojo supports vectorized operations with `SIMD`, but Larecs🌲 does not
currently expose an explicit SIMD-batch interface for component iteration.
Component-processing code should use the [systems and kernels
API](../systems_scheduler): the scheduler runs a system, and the system calls
{{< api SystemContext.run >}} with a kernel that receives a
{{< api KernelContext >}}. The system owns the application logic and lifecycle;
the kernel describes the filtered component work that can execute on the CPU
or GPU.

```mojo {doctest="guide_vectorization" global=true}
from larecs import Scheduler, System, SystemContext, KernelContext, Filter

@fieldwise_init
struct Position(Copyable, Movable, TrivialRegisterPassable):
    var x: Float64
    var y: Float64

@fieldwise_init
struct Velocity(Copyable, Movable, TrivialRegisterPassable):
    var dx: Float64
    var dy: Float64

comptime move_filter = Filter().include[Position].read[Velocity]()

def move_entities(context: KernelContext[move_filter]):
    for entity in context:
        ref pos = entity.get[Position]()
        ref vel = entity.get[Velocity]()
        pos.x += vel.dx
        pos.y += vel.dy

@fieldwise_init
struct Move(System):
    def update(mut self, mut context: SystemContext[...]) raises:
        context.run[move_entities]()
```

```mojo {doctest="guide_vectorization" global=true}
def main() raises:
    var scheduler = Scheduler[Position, Velocity]()
    _ = scheduler.world.storage.add_entities(
        Position(0, 0), Velocity(1, 0), count=10
    )

    scheduler.add_system(Move())
    scheduler.run(1)
```

The CPU path runs the kernel against each matching archetype's homogeneous
component columns. The GPU path distributes the same entity loop across GPU
threads and copies only the component directions declared by the filter. For
example, `move_filter` uploads both component columns but downloads only the
modified `Position` column.

In `Move.update`, pass `on_gpu=True` to run a compatible kernel on an
available accelerator:

```mojo
context.run[move_entities, on_gpu=True]()
```

GPU execution requires GPU-safe component types and the corresponding Mojo
toolchain. If you need explicit CPU `SIMD` batching, that is not part of the
public systems API yet; avoid depending on archetype storage internals, whose
layout and iteration contracts may change.
