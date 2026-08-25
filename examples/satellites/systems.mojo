from std.random import random
from std.python import PythonObject, Python
from larecs import World
from components import Position, Velocity
from parameters import Parameters, GRAVITATIONAL_CONSTANT


def move(mut world: World) raises:
    ref parameters = world.resources.get[Parameters]()

    for entity in world.storage.query[Position, Velocity]():
        ref position = entity.get[Position]()
        ref velocity = entity.get[Velocity]()

        position.x += velocity.x * parameters.dt
        position.y += velocity.y * parameters.dt


def accelerate(mut world: World) raises:
    ref parameters = world.resources.get[Parameters]()
    var constant = -GRAVITATIONAL_CONSTANT * parameters.mass * parameters.dt

    for entity in world.storage.query[Position, Velocity]():
        ref position = entity.get[Position]()
        ref velocity = entity.get[Velocity]()

        var multiplier = constant * (position.x**2 + position.y**2) ** (-1.5)

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


def position_to_numpy(mut world: World, out numpy_array: PythonObject) raises:
    var iterator = world.storage.query[Position]()

    var np = Python.import_module("numpy")
    numpy_array = np.zeros(Python.tuple(len(iterator), 2))

    var i = 0
    for entity in iterator:
        var position = entity.get[Position]()

        numpy_array[i, 0] = position.x
        numpy_array[i, 1] = position.y

        i += 1
