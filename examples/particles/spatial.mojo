"""Checks explicit spatial maintenance and exact particle cluster selection."""

from std.testing import assert_almost_equal, assert_equal
from larecs import (
    ExecutionBackend,
    Filter,
    KernelContext,
    Resources,
    Scheduler,
    System,
    SystemContext,
    World,
)
from std.testing import assert_raises
from larecs import SpatialClassifier, grid_cell, morton_key_3d
from larecs.entity import EntityAccessor


# region model
@fieldwise_init
struct Position(Copyable, Movable, TrivialRegisterPassable):
    """Particle coordinates, using device-compatible scalar arithmetic."""

    var x: Float32
    var y: Float32


@fieldwise_init
struct Velocity(Copyable, Movable, TrivialRegisterPassable):
    """Particle displacement per unit of simulated time."""

    var dx: Float32
    var dy: Float32


@fieldwise_init
struct Time(Copyable, Movable):
    """Shared simulated step length."""

    var delta: Float32


# endregion model


# region kernel
comptime move_filter = Filter().include[Position]().read[Velocity]()
comptime move_resources = Resources().read[Time]()


def move(context: KernelContext[move_filter, move_resources]):
    """Moves each row using its velocity and the shared step length.

    Args:
        context: Matching rows and read-only time.
    """
    ref time = context.resources.get[Time]()
    for particle in context:
        ref position = particle.get[Position]()
        ref velocity = particle.get[Velocity]()
        position.x += velocity.dx * time.delta
        position.y += velocity.dy * time.delta


# endregion kernel


# region classifier
comptime spatial_filter = Filter().read[Position]().exclude[Int32]()


@fieldwise_init
struct Grid(SpatialClassifier):
    """Classifies eligible particles by a bounded planar Morton cell."""

    comptime Accessor = EntityAccessor[spatial_filter]
    var cell_size: Float64

    def classify(self, entity: Self.Accessor) raises -> UInt64:
        """Reads only the declared position input.

        Args:
            entity: Borrowed classifier inputs; never retained.

        Raises:
            Error: If the cell width, coordinates, or cell bounds are invalid.

        Returns:
            The exact cell's Morton key.
        """
        ref position = entity.get[Position]()
        return morton_key_3d(
            grid_cell(Float64(position.x), self.cell_size),
            grid_cell(Float64(position.y), self.cell_size),
        )


# endregion classifier
# region system
@fieldwise_init
struct Move(System):
    """Moves particles and then refreshes their physical placement."""

    def update(mut self, mut context: SystemContext[...]) raises:
        """Runs explicit maintenance after movement completes.

        Args:
            context: Access to the unlocked world.

        Raises:
            Error: If execution or maintenance fails.
        """
        context.run[move]()
        context.world[].maintain_spatial()


# endregion system
# region registration
def run_stage[partitioned: Bool]() raises:
    """Checks the same identities and values under both placement policies.

    Parameters:
        partitioned: Choose growable cluster stores instead of row ordering.

    Raises:
        Error: If classification, selection, movement, or checks fail.
    """
    var world = World[Position, Velocity, Int32]()
    world.resources.add(Time(1))
    var walker = world.storage.add_entity(Position(0.5, 0), Velocity(1, 0))
    var climber = world.storage.add_entity(Position(1.5, 0), Velocity(0, 2))
    var excluded = world.storage.add_entity(Position(-1, 0), Int32(1))
    world.register_spatial_classifier[spatial_filter](
        Grid(cell_size=1), partitioned=partitioned
    )
    world.maintain_spatial()
    assert_equal(world.storage.read[Position](walker).x, 0.5)
    assert_equal(world.storage.read[Position](excluded).x, -1)
    # endregion registration

    # region cluster
    comptime if partitioned:
        # New rows are visible to ordinary execution while still staged.
        var staged = world.storage.add_entity(Position(0.25, 0))
        assert_equal(len(world.storage.query[Filter().read[Position]()]()), 4)
        var context = SystemContext(world)
        with assert_raises():
            _ = context.select_cluster[Filter().read[Position]()](
                morton_key_3d(0, 0)
            )
        world.maintain_spatial()
        var clean_context = SystemContext(world)
        var selected = clean_context.select_cluster[Filter().read[Position]()](
            morton_key_3d(0, 0)
        )
        assert_equal(
            len(selected), 2
        )  # walker and staged; two logical archetypes
        selected.run[move]()  # only walker has Velocity
        assert_equal(len(selected), 2)  # membership stays fixed after the write
        selected^.release()
        world.maintain_spatial()
        assert_equal(world.storage.read[Position](walker).x, 1.5)
        assert_equal(world.storage.read[Position](staged).x, 0.25)
    # endregion cluster

    var scheduler = Scheduler[Position, Velocity, Int32](world^)
    scheduler.add_system(Move())
    scheduler.run(steps=1)
    assert_equal(scheduler.world.storage.read[Position](climber).y, 2)
    assert_equal(
        scheduler.world.storage.read[Position](walker).x,
        Float32(2.5) if partitioned else Float32(1.5),
    )


# region check
def main() raises:
    """Checks grid bounds, default ordering, and partitioned selections.

    Raises:
        Error: If any spatial contract check fails.
    """
    assert_equal(grid_cell(-0.1, 1), -1)
    with assert_raises():
        _ = grid_cell(1048576, 1)
    with assert_raises():
        _ = morton_key_3d(0, -1048577)
    run_stage[False]()
    run_stage[True]()
    print("PASS: row ordering, partition staging, exact selections, and bounds")


# endregion check
