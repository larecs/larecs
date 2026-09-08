"""GPU and CPU system execution benchmarks over a tunable compute-bound kernel.

The movement kernel used by `system_sketch.mojo` is memory-bound: it reads two
components, writes one, and does three floating point operations per entity.
On unified memory hardware there is no bandwidth advantage to win there, so
that kernel measures host/device transfer cost and nothing else.

This benchmark instead runs a central-force orbital integration whose
arithmetic intensity is a compile-time parameter. `steps` controls how many
integration steps each entity performs per launch while the bytes moved stay
fixed, so sweeping `steps` walks the same kernel from memory-bound to
compute-bound and shows where the GPU path starts to pay for itself.

Components are `Float32`. Apple GPUs have no double precision, so the
`Float64` components in `larecs.test_utils` cannot be used on the device.
"""

from std.benchmark import (
    Bench,
    BenchId,
    BenchMetric,
    Bencher,
    ThroughputMeasure,
    keep,
)
from std.math import rsqrt
from std.sys import has_accelerator

from custom_benchmark import DefaultBench

from larecs import Entity, Filter, KernelContext, SystemContext, World


@fieldwise_init
struct Position(TrivialRegisterPassable):
    """A single-precision position, sized for device storage."""

    var x: Float32
    """The horizontal position coordinate."""

    var y: Float32
    """The vertical position coordinate."""


@fieldwise_init
struct Velocity(TrivialRegisterPassable):
    """A single-precision velocity, sized for device storage."""

    var dx: Float32
    """The horizontal velocity component."""

    var dy: Float32
    """The vertical velocity component."""


comptime ENTITY_COUNT = 250_000
"""Number of entities each benchmark integrates."""

comptime WorldType = World[Position, Velocity]
"""The world type used by these benchmarks."""

comptime ContextType = SystemContext[MutUntrackedOrigin, Position, Velocity]
"""The system context type used by these benchmarks."""

comptime TIME_STEP: Float32 = 0.001
"""Integration step size."""

comptime GRAVITATIONAL_PARAMETER: Float32 = 1.0
"""Standard gravitational parameter of the central body."""

comptime SOFTENING: Float32 = 1e-3
"""Softening term keeping the force finite at the origin."""

comptime FLOPS_PER_STEP = 18
"""Floating point operations one integration step performs per entity.

Four for the softened square radius, one for the reciprocal square root,
three for the acceleration magnitude, six for the two velocity updates, and
four for the two position updates.
"""

comptime BYTES_PER_ENTITY = 32
"""Bytes of component traffic per entity per launch: 16 read, 16 written."""


def integrate_orbit[
    steps: Int
](context: KernelContext[Filter().include[Position, Velocity]()]):
    """Advances every matching entity along a central-force orbit.

    The body of the step loop is deliberately free of memory traffic: the
    entity's state is loaded once into locals, integrated `steps` times, and
    stored once. Raising `steps` therefore raises arithmetic intensity
    without changing the bytes moved.

    Bound directly to `FILTER` rather than taking a free `filter: Filter`
    type parameter: `Position` and `Velocity` must both be provably
    writable at this function's own elaboration, which an unbound
    `filter: Filter` parameter cannot prove for any specific component --
    see `read`/`write` on `Filter`.

    Parameters:
        steps: The number of integration steps to perform per entity.

    Args:
        context: The CPU or GPU execution context for the filtered rows.
    """
    for entity in context:
        ref position = entity.get[Position]()
        ref velocity = entity.get[Velocity]()

        var x = position.x
        var y = position.y
        var velocity_x = velocity.dx
        var velocity_y = velocity.dy

        for _ in range(steps):
            var inverse_radius = rsqrt(x * x + y * y + SOFTENING)
            var acceleration = (
                -GRAVITATIONAL_PARAMETER
                * inverse_radius
                * inverse_radius
                * inverse_radius
            )
            velocity_x += acceleration * x * TIME_STEP
            velocity_y += acceleration * y * TIME_STEP
            x += velocity_x * TIME_STEP
            y += velocity_y * TIME_STEP

        position.x = x
        position.y = y
        velocity.dx = velocity_x
        velocity.dy = velocity_y


def _populate(mut world: WorldType) raises -> Entity:
    """Fills a world with entities spread over a ring of orbital radii.

    Every entity is given a distinct radius so no thread's arithmetic can be
    folded away as a shared constant, and a tangential velocity roughly
    matching a circular orbit so the integration stays numerically bounded.

    Args:
        world: The world to populate.

    Raises:
        LarecsError: If the entities cannot be added.

    Returns:
        The first entity added, so a caller can observe the kernel's output.
    """
    var first = Entity()
    var index = 0
    for ref entity in world.storage.add_entities(
        Position(1.0, 0.0), Velocity(0.0, 1.0), count=ENTITY_COUNT
    ):
        var radius = 1.0 + Float32(index) * 1e-6
        entity.unsafe_get[Position]().x = radius
        entity.unsafe_get[Velocity]().dy = rsqrt(radius)
        if index == 0:
            first = entity.get_entity()
        index += 1
    return first


def _run_once[steps: Int, on_gpu: Bool](mut world: WorldType) raises:
    """Executes one launch of the integration kernel over `world`.

    Parameters:
        steps: The number of integration steps per entity.
        on_gpu: Whether to execute against device storage.

    Args:
        world: The world whose entities are integrated.
    """
    var context = ContextType(
        Pointer(to=world).unsafe_origin_cast[MutUntrackedOrigin]()[]
    )
    context.run[integrate_orbit[steps], on_gpu=on_gpu]()


def _benchmark[steps: Int, on_gpu: Bool](mut bencher: Bencher):
    """Benchmarks one launch of the integration kernel.

    A warm-up launch runs before measurement. On the GPU path the first
    launch pays just-in-time kernel compilation, which is a one-time startup
    cost rather than a per-frame one and would otherwise dominate the first
    measured iteration.

    Parameters:
        steps: The number of integration steps per entity.
        on_gpu: Whether to execute against device storage.

    Args:
        bencher: The benchmark driver.
    """
    var world = WorldType()
    var probe = Entity()
    try:
        probe = _populate(world)
        _run_once[steps, on_gpu](world)
    except e:
        print(e)

    @always_inline
    def bench_fn() {mut world, imm probe}:
        try:
            _run_once[steps, on_gpu](world)
            keep(world.storage.get[Position](probe).x)
        except e:
            print(e)

    bencher.iter(bench_fn)


def _register[
    steps: Int, on_gpu: Bool
](mut bench: Bench, label: String, iterations: Optional[Int] = None) raises:
    """Registers one point of the arithmetic intensity sweep.

    Parameters:
        steps: The number of integration steps per entity.
        on_gpu: Whether to execute against device storage.

    Args:
        bench: The benchmark driver to register on.
        label: The name shown in the report.
        iterations: A fixed iteration count, for entries whose per-iteration
            cost is high enough that the driver's default runtime target
            would make the suite unreasonably slow.

    Raises:
        Error: If the driver rejects the registration.
    """
    bench.bench_function(
        _benchmark[steps, on_gpu],
        BenchId(label),
        [
            ThroughputMeasure(
                BenchMetric.flops, ENTITY_COUNT * steps * FLOPS_PER_STEP
            ),
            ThroughputMeasure(
                BenchMetric.bytes, ENTITY_COUNT * BYTES_PER_ENTITY
            ),
        ],
        fixed_iterations=iterations,
    )


def run_all_gpu_system_benchmarks() raises:
    """Runs the system execution benchmarks and prints a report.

    Raises:
        Error: If a benchmark fails to run.
    """
    var bench = DefaultBench()
    run_all_gpu_system_benchmarks(bench)
    bench.dump_report()


def run_all_gpu_system_benchmarks(mut bench: Bench) raises:
    """Registers the arithmetic intensity sweep on the given driver.

    The sweep runs the same kernel at four arithmetic intensities on each
    execution target. The first point is memory-bound and measures little
    beyond host/device transfer cost; the last is deeply compute-bound and
    measures the kernel itself. The GPU entries are registered only when an
    accelerator is present, so the suite still runs without one.

    Args:
        bench: The benchmark driver to register on.

    Raises:
        Error: If the driver rejects a registration.
    """
    _register[1, False](bench, "system cpu, 1 step (memory bound)")
    _register[8, False](bench, "system cpu, 8 steps")
    _register[64, False](bench, "system cpu, 64 steps", iterations=10)
    _register[512, False](
        bench, "system cpu, 512 steps (compute bound)", iterations=3
    )

    comptime if has_accelerator():
        _register[1, True](bench, "system gpu, 1 step (memory bound)")
        _register[8, True](bench, "system gpu, 8 steps")
        _register[64, True](bench, "system gpu, 64 steps")
        _register[512, True](bench, "system gpu, 512 steps (compute bound)")


def main() raises:
    """Runs the system execution benchmarks standalone.

    Raises:
        Error: If a benchmark fails to run.
    """
    run_all_gpu_system_benchmarks()
