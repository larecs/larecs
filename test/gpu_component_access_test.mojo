# SKIP_ASAN
# SKIP_DEBUG

# Every GPU test file needs both markers above: a `for entity in context`
# GPU kernel reliably crashes Apple's Metal compiler when compiled with
# `-g`. See "Known issues" in AGENTS.md for the full writeup.

# Covers `Filter.read`/`Filter.write`, the per-component access modes that
# let `SystemContext.run`'s GPU path skip an upload or download direction
# it doesn't need (see `Filter.include`'s docstring and `SystemContext.run`
# in src/larecs/system.mojo). `EntityAccessor.get`/`set` reject the wrong
# direction at compile time, so the behavior worth testing at runtime is
# what `run` transfers: a write-only component must still end up correct on
# the host despite skipping its upload, a read-only component must still
# reflect the host's latest value despite skipping its download, and
# `include` -- unchanged by any of this -- must keep doing both.

from std.sys import has_accelerator
from std.testing import *

from larecs import World, SystemContext, KernelContext, Filter


# `TrivialRegisterPassable` satisfies `GPUComponentType` (see
# component.mojo): `SystemContext.run(..., on_gpu=True)` moves component
# columns as raw bytes, which is only compile-time-permitted for a type
# with no non-trivial state.
@fieldwise_init
struct Value(Copyable, TrivialRegisterPassable):
    var v: Int32


@fieldwise_init
struct Doubled(Copyable, TrivialRegisterPassable):
    var v: Int32


def fill_value(context: KernelContext[Filter().write[Value]()]):
    """Overwrites `Value` with a fixed value, never reading its prior state."""
    for entity in context:
        entity.set[Value](Value(10))


def double_value(
    context: KernelContext[Filter().read[Value]().write[Doubled]()],
):
    """Reads `Value` and writes `Doubled = Value * 2`, never writing `Value`."""
    for entity in context:
        entity.set[Doubled](Doubled(entity.get[Value]().v * 2))


def bump_both(context: KernelContext[Filter().include[Value, Doubled]()]):
    """Reads and writes both components, exercising the `include` default."""
    for entity in context:
        entity.get[Value]().v += 1
        entity.get[Doubled]().v += entity.get[Value]().v


def test_gpu_write_only_component_downloads_without_a_prior_upload() raises:
    """A write-only filter skips uploading `Value` but still downloads it.

    `Value` has no device column yet, so `run`'s upload branch must take the
    write-only path (`DeviceComponentStorage.ensure_column`, which sizes a
    column without transferring host data) rather than `copy_from_host`.
    Seeding each entity with a different `Value` that the kernel never reads
    confirms the downloaded result depends only on what the kernel wrote.
    """
    comptime if not has_accelerator():
        return

    var world = World[Value, Doubled]()
    var a = world.storage.add_entity(Value(1), Doubled(0))
    var b = world.storage.add_entity(Value(-7), Doubled(0))
    var c = world.storage.add_entity(Value(999), Doubled(0))

    var context = SystemContext(world)
    context.run[fill_value, on_gpu=True]()

    assert_equal(world.storage.get[Value](a).v, 10)
    assert_equal(world.storage.get[Value](b).v, 10)
    assert_equal(world.storage.get[Value](c).v, 10)


def test_gpu_read_only_component_uploads_latest_host_state() raises:
    """A read-only filter re-uploads `Value` from the host on every run.

    `Value` already has a device column holding `10` in every row, left
    behind by an earlier write-only kernel run against this same world (GPU
    columns are reused across calls). This test then overwrites one
    entity's `Value` directly on the host, bypassing any kernel, before
    running a kernel that only reads `Value`. If the read-only upload were
    ever skipped because a device column already exists for `Value` -- an
    easy regression to introduce once `run` starts reusing device storage
    across calls -- this kernel would compute from the stale device value
    instead of the fresh host one, and the assertion on `a` below would see
    `20` instead of `42`.
    """
    comptime if not has_accelerator():
        return

    var world = World[Value, Doubled]()
    var a = world.storage.add_entity(Value(1), Doubled(0))
    var b = world.storage.add_entity(Value(2), Doubled(0))

    var context = SystemContext(world)

    # Give `Value` a device column with stale data, mimicking a world whose
    # device storage was already used by an earlier system this frame.
    context.run[fill_value, on_gpu=True]()
    assert_equal(world.storage.get[Value](a).v, 10)

    # Bypass the kernel entirely -- host and device now disagree about `a`.
    world.storage.get[Value](a) = Value(21)

    context.run[double_value, on_gpu=True]()

    assert_equal(world.storage.get[Doubled](a).v, 42)
    assert_equal(world.storage.get[Doubled](b).v, 20)

    # `Value` is read-only for `double_value`; its download must have been
    # skipped, leaving the host value exactly as this test last set it.
    assert_equal(world.storage.get[Value](a).v, 21)
    assert_equal(world.storage.get[Value](b).v, 10)


def test_gpu_include_still_reads_and_writes_both_directions() raises:
    """`Filter.include` keeps transferring both directions for every component.

    Guards the compatibility claim in `Filter.include`'s docstring: every
    call site written before `read`/`write` existed must keep uploading and
    downloading every included component exactly as before, regardless of
    what `read`/`write` now let a filter opt out of.
    """
    comptime if not has_accelerator():
        return

    var world = World[Value, Doubled]()
    var a = world.storage.add_entity(Value(1), Doubled(1))
    var b = world.storage.add_entity(Value(5), Doubled(5))

    var context = SystemContext(world)
    context.run[bump_both, on_gpu=True]()

    assert_equal(world.storage.get[Value](a).v, 2)
    assert_equal(world.storage.get[Doubled](a).v, 3)
    assert_equal(world.storage.get[Value](b).v, 6)
    assert_equal(world.storage.get[Doubled](b).v, 11)


comptime functions = __functions_in_module()


def main() raises:
    TestSuite.discover_tests[functions]().run()
