# SKIP_ASAN
# SKIP_DEBUG

# The `-g` in `SKIP_DEBUG` above is load-bearing, not cosmetic: compiling a
# `for entity in context` GPU kernel (`KernelContext`'s `EntityAccessorIterator`,
# which lowers to `raise StopIteration()`-driven control flow) with debug info
# reliably crashes Apple's AGX Metal compiler backend (`MTLCompilerService`
# SIGABRTs inside `llvm::report_fatal_error`, surfacing here as
# `XPC_ERROR_CONNECTION_INTERRUPTED`). The same kernel compiles and runs
# correctly without `-g`. See "Known issues" in AGENTS.md for the full
# writeup and reproduction notes.

from std.sys import has_accelerator
from std.testing import *

from larecs import World, SystemContext, KernelContext, Filter


@fieldwise_init
struct Position(Copyable):
    var x: Float32


@fieldwise_init
struct Velocity(Copyable):
    var dx: Float32


@fieldwise_init
struct Tag(Copyable):
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


comptime functions = __functions_in_module()


def main() raises:
    TestSuite.discover_tests[functions]().run()
