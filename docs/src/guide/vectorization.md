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
the kernel describes the filtered component work that can execute on the host
or device.

```mojo {doctest="guide_vectorization" global=true}
from larecs import ExecutionBackend, Scheduler, System, SystemContext, KernelContext, Filter

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

The sequential host path calls the kernel once per non-empty matching
physical store, and each call iterates that store's component columns. With
`threaded=True`, each store is split into kernel chunks that may run
concurrently, one call per chunk. The device path distributes the same entity
loop across GPU threads in one launch and copies only the component directions
declared by the filter. For example, `move_filter` uploads both component
columns, unless the world reuses unchanged device copies, and downloads only
the modified `Position` column.

In `Move.update`, pass `backend=ExecutionBackend.DEVICE` to run a compatible
kernel on an available accelerator:

Use `context.run[move_entities, backend=ExecutionBackend.DEVICE]()` after
importing `ExecutionBackend` from `larecs`.

Device execution requires device-safe component types and the corresponding Mojo
toolchain. If you need explicit CPU `SIMD` batching, that is not part of the
public systems API yet; avoid depending on archetype storage internals, whose
layout and iteration contracts may change.

The default is `ExecutionBackend.HOST`. Selecting DEVICE raises when an
accelerator is unavailable; it never falls back to host execution.
