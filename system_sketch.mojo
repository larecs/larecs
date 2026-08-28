"""Minimal GPU-backed sketch of the systems API.

It demonstrates the first execution boundary: the CPU path runs against the
archetype-backed ECS storage, while the GPU path owns device-resident SoA
component columns, launches a Mojo GPU kernel, and copies results back only for
verification.
"""

from std.sys import has_accelerator
from std.sys.info import is_gpu
from std.time import perf_counter

from larecs import (
    World,
    Scheduler,
    System,
    ComponentType,
    Filter,
    SystemContext,
    KernelContext,
)


@fieldwise_init
struct Position(Copyable):
    var x: Float32
    var y: Float32


@fieldwise_init
struct Velocity(Copyable):
    var dx: Float32
    var dy: Float32


@fieldwise_init
struct Name(Copyable):
    var name: String


comptime ENTITY_COUNT = 10_000_000


@fieldwise_init
struct Move(System):
    def update[
        *WorldTs: ComponentType
    ](mut self, mut context: SystemContext[*WorldTs]) raises:
        """Runs the movement kernel for entities with position and velocity."""

        def move_positions[filter: Filter](context: KernelContext[filter]):
            """Moves every position in the kernel's assigned row range.

            Args:
                context: The CPU or GPU execution context for the filtered rows.
            """
            for entity in context:
                ref position = entity.get[Position]()
                ref velocity = entity.get[Velocity]()
                position.x += velocity.dx
                position.y += velocity.dy

        var start = perf_counter()
        context.run[
            move_positions[Filter().include[Position, Velocity]()],
            on_gpu=True,
        ]()
        print(
            t"Overall GPU execution time: {(perf_counter() - start) * 1000} ms"
        )

        start = perf_counter()
        context.run[
            move_positions[Filter().include[Position, Velocity]()],
            on_gpu=False,
        ]()
        print(
            t"Overall CPU execution time: {(perf_counter() - start) * 1000} ms"
        )


def main() raises:
    comptime if not has_accelerator():
        print("No compatible GPU found")
    else:
        var world = World[Position, Velocity, Name]()
        var scheduler = Scheduler[Position, Velocity, Name](world^)
        scheduler.add_system(Move())

        # Store host entities in the archetype-backed ECS storage. This keeps
        # the CPU system on the same entity/component model as the public API
        # instead of treating the world as a pair of untyped dense columns.
        for i in range(ENTITY_COUNT):
            var x = Float32(i)
            var y = Float32(-i)
            _ = scheduler.world.storage.add_entity(
                Position(x=x, y=y),
                Velocity(dx=2.0, dy=-2.0),
            )

        # Add an entity with a different component composition. The CPU
        # filter must skip this archetype while still updating the matching
        # Position + Velocity archetype.
        var static_entity = scheduler.world.storage.add_entity(
            Position(x=1000.0, y=-1000.0)
        )

        scheduler.update()

        # Capture the host value before copying the device buffer. The device
        # copy returns a separate list and must not be used as a host-storage
        # synchronization operation.
        var host_index = 0
        for entity in scheduler.world.storage.query[Position, Velocity]():
            if host_index == 0:
                print(
                    t"Host position[0] = ({ entity.get[Position]().x },"
                    t" { entity.get[Position]().y })"
                )
                assert entity.get[Position]().x == 2.0
                assert entity.get[Position]().y == -2.0
            elif host_index == 1:
                assert entity.get[Position]().x == 3.0
                assert entity.get[Position]().y == -3.0
            elif host_index == ENTITY_COUNT - 1:
                assert entity.get[Position]().x == Float32(ENTITY_COUNT + 1)
                assert entity.get[Position]().y == -Float32(ENTITY_COUNT + 1)
            host_index += 1
        assert host_index == ENTITY_COUNT
        assert scheduler.world.storage.get[Position](static_entity).x == 1000.0
        assert scheduler.world.storage.get[Position](static_entity).y == -1000.0

        var gpu_positions = (
            scheduler.world._device_storage.unsafe_value().copy_to_host[
                Position
            ]()
        )
        print(
            t"GPU position[0] = ({ gpu_positions[0].x },"
            t" { gpu_positions[0].y })"
        )
        assert gpu_positions[0].x == 1.0
        assert gpu_positions[0].y == -1.0
        assert gpu_positions[1].x == 1.0
        assert gpu_positions[1].y == -1.0
        assert gpu_positions[ENTITY_COUNT - 1].x == 1.0
        assert gpu_positions[ENTITY_COUNT - 1].y == -1.0
