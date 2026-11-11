"""Reads, changes, adds, removes, and replaces components of single particles.

Region markers supply excerpts for the single-entity guide.
"""

from std.testing import (
    assert_almost_equal,
    assert_equal,
    assert_false,
    assert_raises,
    assert_true,
)

from larecs import World


# region components
@fieldwise_init
struct Position(Copyable, Movable):
    """Where a particle is."""

    var x: Float64
    """Horizontal coordinate."""
    var y: Float64
    """Vertical coordinate."""


@fieldwise_init
struct Velocity(Copyable, Movable):
    """How far a particle moves per unit of time."""

    var dx: Float64
    """Horizontal speed."""
    var dy: Float64
    """Vertical speed."""


@fieldwise_init
struct Frozen(Copyable, Movable):
    """Marks a particle that stopped and remembers its last speed."""

    var speed: Float64
    """Speed before the particle froze."""


# endregion components


def main() raises:
    """Changes single particles and checks every result.

    Raises:
        Error: If an operation or a result check fails.
    """
    # region setup
    var world = World[Position, Velocity, Frozen]()
    var walker = world.storage.add_entity(Position(0, 0), Velocity(1, 0))
    var marker = world.storage.add_entity(Position(3, 3))
    # endregion setup

    # region get
    ref position = world.storage.get[Position](walker)
    position.x = 5
    assert_almost_equal(world.storage.get[Position](walker).x, 5)

    world.storage.get[Position](walker) = Position(10, 0)
    assert_almost_equal(world.storage.get[Position](walker).x, 10)
    # endregion get

    # region has
    assert_true(world.storage.has[Velocity](walker))
    assert_false(world.storage.has[Velocity](marker))
    with assert_raises():
        _ = world.storage.get[Velocity](marker)
    # endregion has

    # region set
    world.storage.set(walker, Position(0, 0), Velocity(2, 0))
    assert_almost_equal(world.storage.get[Velocity](walker).dx, 2)
    # endregion set

    # region add_remove
    world.storage.add(marker, Velocity(0, 1))
    assert_true(world.storage.has[Velocity](marker))

    world.storage.remove[Velocity](marker)
    assert_false(world.storage.has[Velocity](marker))
    # endregion add_remove

    # region replace
    world.storage.replace[Velocity]().by(Frozen(2), entity=walker)
    assert_false(world.storage.has[Velocity](walker))
    assert_almost_equal(world.storage.get[Frozen](walker).speed, 2)
    # endregion replace

    # region failures
    with assert_raises():
        world.storage.set(marker, Velocity(1, 1))
    world.storage.remove_entity(marker)
    with assert_raises():
        _ = world.storage.get[Position](marker)
    with assert_raises():
        world.storage.add(walker, Frozen(0))
    # endregion failures

    assert_equal(len(world), 1)
    print("PASS: single-particle reads, changes, and composition changes")
