# SKIP_ASAN
# SKIP_DEBUG

# Every GPU test file needs both markers above: a `for entity in context`
# GPU kernel reliably crashes Apple's Metal compiler when compiled with
# `-g`. See "Known issues" in AGENTS.md for the full writeup.

from std.sys import has_accelerator
from std.testing import *

from larecs import World, SystemContext, KernelContext, Filter


# `TrivialRegisterPassable` on every component below satisfies
# `GPUComponentType` (see component.mojo): `SystemContext.run(...,
# on_gpu=True)` moves component columns as raw bytes, which is only
# compile-time-permitted for a type with no non-trivial state.
@fieldwise_init
struct Position(Copyable, TrivialRegisterPassable):
    var x: Float32


@fieldwise_init
struct Velocity(Copyable, TrivialRegisterPassable):
    var dx: Float32


@fieldwise_init
struct Tag(Copyable, TrivialRegisterPassable):
    var t: Int32


def bump(context: KernelContext[Filter().include[Position, Velocity]()]):
    """Adds `Velocity` into `Position` for every matching row."""
    for entity in context:
        entity.get[Position]().x += entity.get[Velocity]().dx


def test_gpu_run_covers_every_matching_archetype() raises:
    """A GPU-run filter matching multiple archetypes updates every row.

    Before this test existed, `SystemContext.run`'s GPU upload path copied
    every matching archetype's column to device offset zero (rather than the
    running offset the download path already used), so the second matching
    archetype silently overwrote the first and any archetype after the first
    two was never uploaded to a valid location at all. This covers a filter
    that matches two archetypes and excludes a third, mirroring a filter
    that matches multiple, differently-composed entity groups.
    """
    comptime if not has_accelerator():
        return

    var world = World[Position, Velocity, Tag]()

    # Archetype A: Position + Velocity.
    var a = world.storage.add_entity(Position(0.0), Velocity(1.0))
    var b = world.storage.add_entity(Position(10.0), Velocity(1.0))

    # Archetype B: Position + Velocity + Tag. Also matches the filter, since
    # the filter only requires Position and Velocity.
    var c = world.storage.add_entity(Position(100.0), Velocity(1.0), Tag(1))
    var d = world.storage.add_entity(Position(200.0), Velocity(1.0), Tag(1))

    # Archetype C: Position + Tag, no Velocity. Does not match the filter and
    # must be left untouched.
    var e = world.storage.add_entity(Position(1000.0), Tag(1))

    var context = SystemContext(world)
    context.run[bump, on_gpu=True]()

    assert_equal(world.storage.get[Position](a).x, 1.0)
    assert_equal(world.storage.get[Position](b).x, 11.0)
    assert_equal(world.storage.get[Position](c).x, 101.0)
    assert_equal(world.storage.get[Position](d).x, 201.0)
    assert_equal(world.storage.get[Position](e).x, 1000.0)


def test_gpu_run_raises_a_clear_error_without_device_storage() raises:
    """`on_gpu=True` raises a legible error when the world has no working
    device storage, instead of an opaque `EmptyOptionalError`.

    `World.__init__` already falls back to an empty `_device_storage` when
    `DeviceContext()` fails (e.g. no accelerator, or a driver-level
    failure despite `has_accelerator()` being true at compile time). Before
    this fix, `SystemContext.run(..., on_gpu=True)` unwrapped that
    `Optional` directly with `[]`, which raises `EmptyOptionalError`, an
    error type that names neither the world, the requested run, nor what
    to do about it. This test forces that fallback path directly (rather
    than relying on a specific `DeviceContext()` failure) by clearing an
    otherwise-working world's device storage, since this machine having an
    accelerator is exactly what makes `on_gpu=True` reach this branch at
    all -- see the `has_accelerator()` guard below.
    """
    comptime if not has_accelerator():
        return

    var world = World[Position, Velocity, Tag]()
    _ = world.storage.add_entity(Position(0.0), Velocity(1.0))
    world._device_storage = None

    var context = SystemContext(world)

    var raised = False
    try:
        context.run[bump, on_gpu=True]()
    except e:
        raised = True
        assert_true("device" in String(e))

    assert_true(raised)


comptime functions = __functions_in_module()


def main() raises:
    TestSuite.discover_tests[functions]().run()
