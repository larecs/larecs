from std.random import random
from std.python import PythonObject, Python
from larecs import World, SystemContext, KernelContext, Filter, Resources
from components import Position, Velocity
from parameters import Parameters, GRAVITATIONAL_CONSTANT


def move(
    context: KernelContext[
        Filter().include[Position, Velocity](), Resources[Parameters]()
    ]
):
    ref parameters = context.resources.get[Parameters]()

    for entity in context:
        ref position = entity.get[Position]()
        ref velocity = entity.get[Velocity]()

        position.x += velocity.x * parameters.dt
        position.y += velocity.y * parameters.dt


def accelerate(
    context: KernelContext[
        Filter().include[Position, Velocity](), Resources[Parameters]()
    ]
):
    ref parameters = context.resources.get[Parameters]()
    var constant = -GRAVITATIONAL_CONSTANT * parameters.mass * parameters.dt

    for entity in context:
        ref position = entity.get[Position]()
        ref velocity = entity.get[Velocity]()

        var multiplier = constant * (position.x**2 + position.y**2) ** (
            -1.5
        )

        velocity.x += position.x * multiplier
        velocity.y += position.y * multiplier


def get_random_position() -> Position:
    return Position(
        x=std.random.random_float64(-1_000_000, 1_000_000),
        y=std.random.random_float64(30_000_000, 40_000_000),
    )


def get_random_velocity() -> Velocity:
    return Velocity(
        std.random.random_float64(2000, 4000)
        * (std.random.random_si64(0, 1) * 2 - 1).cast[DType.float64](),
        std.random.random_float64(-500, 500),
    )


def add_satellites(mut world: World, count: Int) raises:
    for _ in range(count):
        _ = world.storage.add_entity(
            get_random_position(), get_random_velocity()
        )


def position_to_numpy(
    mut context: SystemContext[...], out numpy_array: PythonObject
) raises:
    var np = Python.import_module("numpy")

    var length = 0

    def count_position_entities(
        context: KernelContext[Filter().include[Position]()],
    ) {mut length}:
        for _ in context:
            length += 1

    context.run(count_position_entities)

    numpy_array = np.zeros(Python.tuple(length, 2))

    def collect_positions(
        context: KernelContext[Filter().include[Position]()],
    ) {mut numpy_array}:
        for entity in context:
            ref position = entity.get[Position]()

            try:
                numpy_array[entity.idx, 0] = position.x
                numpy_array[entity.idx, 1] = position.y
            except:
                pass

    context.run(collect_positions)
