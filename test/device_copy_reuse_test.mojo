# SKIP_ASAN
# SKIP_DEBUG

from std.gpu import global_idx
from std.reflection import reflect
from std.sys import has_accelerator, size_of
from std.sys.info import is_gpu
from std.testing import *

from larecs import (
    World,
    SystemContext,
    KernelContext,
    Filter,
    Resources,
    ResourceType,
    BufferResource,
    ReadBuffer,
    DevicePassableResource,
    ResourceAdapter,
    ResourceDeviceCache,
)
from larecs.resource import ResourceStorage
from larecs.resource_adapter import _TransferStats

comptime Samples = BufferResource[DType.int32]
comptime sample_count = 64
comptime full_upload = sample_count * size_of[Int32]() + size_of[
    ReadBuffer[DType.int32]
]() + size_of[Int32]()
"""Bytes uploaded by `sum_kernel`: samples, their descriptor, and `Offset`."""


@fieldwise_init
struct Offset(ResourceType):
    """Plain read resource added to every row."""

    var value: Int32


@fieldwise_init
struct Counter(ResourceType):
    """Plain resource written by the device kernel."""

    var value: Int32


comptime sum_spec = Resources().read[Samples, Offset]()


def sum_kernel(context: KernelContext[Filter().write[Int32](), sum_spec]):
    """Writes the first sample plus the offset to every row.

    Args:
        context: Write-only rows and read-only resources.
    """
    var value = (
        context.resources.get[Samples]()[0]
        + context.resources.get[Offset]().value
    )
    for entity in context:
        entity.set(value)


def count_kernel(
    context: KernelContext[
        Filter().write[Int32](), Resources().read_write[Counter]()
    ]
):
    """Increments the counter once and writes its new value to every row.

    Args:
        context: Write-only rows and the mutable counter.
    """
    var value = context.resources.get[Counter]().value + 1
    for entity in context:
        entity.set(value)
    comptime if is_gpu():
        if global_idx.x != 0:
            return
    context.resources.get[Counter]().value = value


def host_write_offset(
    context: KernelContext[Filter().write[Int32](), Resources().write[Offset]()]
):
    """Replaces the offset through host write access.

    Args:
        context: Write-only rows and the set-only offset.
    """
    context.resources.set(Offset(20))


def host_read_write_offset(
    context: KernelContext[
        Filter().write[Int32](), Resources().read_write[Offset]()
    ]
):
    """Increments the offset through host read_write access.

    Args:
        context: Write-only rows and the mutable offset.
    """
    context.resources.get[Offset]().value += 1


def host_read_offset(
    context: KernelContext[Filter().write[Int32](), Resources().read[Offset]()]
):
    """Reads the offset without mutating it.

    Args:
        context: Write-only rows and the read-only offset.
    """
    var value = context.resources.get[Offset]().value
    for entity in context:
        entity.set(value)


struct Flaky(DevicePassableResource):
    """Adapted resource whose preparation can fail after its upload."""

    comptime KernelView = ReadBuffer[DType.int32]
    comptime Adapter = FlakyAdapter
    var samples: List[Int32]
    var fail: Bool

    def __init__(out self, var samples: List[Int32], fail: Bool):
        """Creates the source.

        Args:
            samples: Owned sample values.
            fail: Whether preparation raises after uploading.
        """
        self.samples = samples^
        self.fail = fail


struct FlakyAdapter(ResourceAdapter):
    """Uploads samples, then optionally raises."""

    comptime Source = Flaky
    comptime View = ReadBuffer[DType.int32]

    @staticmethod
    def validate(source: Self.Source) raises:
        """Accepts every source.

        Args:
            source: Current source.
        """
        pass

    @staticmethod
    def bind_host(source: Self.Source) raises -> Self.View:
        """Borrows host samples.

        Args:
            source: Current source.

        Returns:
            Host view.
        """
        return {
            Pointer[Int32, ImmUntrackedOrigin](
                unsafe_from_address=Int(source.samples.unsafe_ptr())
            ),
            len(source.samples),
        }

    @staticmethod
    def prepare_device(
        source: Self.Source, mut cache: ResourceDeviceCache
    ) raises -> Self.View:
        """Uploads samples and raises afterwards if requested.

        Args:
            source: Current source.
            cache: Leased cache.

        Raises:
            Error: If failure injection is enabled.

        Returns:
            Device view.
        """
        var pointer = cache.upload[Int32](0, Span(source.samples))
        if source.fail:
            raise Error("Injected failure after resource upload")
        return {pointer, len(source.samples)}


def flaky_kernel(
    context: KernelContext[Filter().write[Int32](), Resources().read[Flaky]()]
):
    """Writes the first flaky sample to every row.

    Args:
        context: Write-only rows and the flaky view.
    """
    var value = context.resources.get[Flaky]()[0]
    for entity in context:
        entity.set(value)


def _samples(first: Int32) -> Samples:
    """Builds a sample buffer starting with `first`.

    Args:
        first: First sample value.

    Returns:
        A buffer of `sample_count` samples.
    """
    var samples = List[Int32](length=sample_count, fill=0)
    samples[0] = first
    return Samples(samples^)


def _world() raises -> World[Int32]:
    """Creates a world with samples, an offset, and a few rows.

    Raises:
        Error: If adding resources or entities fails.

    Returns:
        The world, with device copy reuse still disabled.
    """
    var world = World[Int32]()
    world.resources.add(_samples(1), Offset(10))
    _ = world.storage.add_entities(Int32(0), count=5)
    return world^


def _revision[T: ResourceType](world: World[Int32]) -> UInt64:
    """Returns a resource's current revision.

    Parameters:
        T: Resource type.

    Args:
        world: World to inspect.

    Returns:
        The revision, or 0 if the resource is missing.
    """
    return world.resources._revision(reflect[T].name())


def _check_rows(mut world: World[Int32], expected: Int32) raises:
    """Checks every row value.

    Args:
        world: World to inspect.
        expected: Required value.

    Raises:
        Error: If any row differs.
    """
    for entity in world.storage.query[Filter().include[Int32]()]():
        assert_equal(entity.get[Int32](), expected)


def _run_sum(mut world: World[Int32]) raises -> Int:
    """Runs `sum_kernel` on the device.

    Args:
        world: World to run on.

    Raises:
        Error: If execution fails.

    Returns:
        Bytes uploaded by the invocation.
    """
    var context = SystemContext(world)
    context.run[sum_kernel, on_device=True]()
    return world._last_device_upload.bytes


def test_revisions_advance_on_mutating_access() raises:
    """Checks every host operation that must or must not advance revisions.

    Raises:
        Error: If a revision changes unexpectedly or fails to advance.
    """
    var world = _world()
    var revision = _revision[Offset](world)
    assert_true(revision > 0)
    assert_equal(world.resources.read[Offset]().value, 10)
    assert_equal(_revision[Offset](world), revision)

    _ = world.resources.get[Offset]()
    assert_true(_revision[Offset](world) > revision)
    revision = _revision[Offset](world)

    world.resources.set(Offset(11))
    assert_true(_revision[Offset](world) > revision)
    revision = _revision[Offset](world)

    world.resources.set[add_if_not_found=True](Offset(12), Counter(0))
    assert_true(_revision[Offset](world) > revision)
    assert_true(_revision[Counter](world) > _revision[Offset](world))
    revision = _revision[Offset](world)

    var context = SystemContext(world)
    context.run[host_read_offset]()
    assert_equal(_revision[Offset](world), revision)
    context.run[host_write_offset]()
    assert_true(_revision[Offset](world) > revision)
    revision = _revision[Offset](world)
    context.run[host_read_write_offset]()
    assert_true(_revision[Offset](world) > revision)
    assert_equal(world.resources.read[Offset]().value, 21)

    world.resources.remove[Offset]()
    assert_equal(_revision[Offset](world), 0)


def test_device_records_are_dropped() raises:
    """Checks invalidation, removal, disabling, and copies without a device.

    Raises:
        Error: If a device copy record survives an operation that drops it.
    """
    var world = _world()
    assert_false(world.resources._reuse_device)
    comptime offset_id = reflect[Offset].name()
    comptime samples_id = reflect[Samples].name()
    world.reuse_device_copies(True)

    world.resources._device_revisions[offset_id] = _revision[Offset](world)
    world.resources._device_revisions[samples_id] = _revision[Samples](world)
    world.resources.invalidate_device[Offset]()
    assert_false(offset_id in world.resources._device_revisions)
    assert_true(samples_id in world.resources._device_revisions)

    var copied = world.copy()
    assert_true(copied.resources._reuse_device)
    assert_equal(len(copied.resources._device_revisions), 0)
    assert_equal(_revision[Samples](copied), _revision[Samples](world))

    world.invalidate_device_copies()
    assert_equal(len(world.resources._device_revisions), 0)

    world.resources._device_revisions[samples_id] = _revision[Samples](world)
    world.resources.remove[Samples]()
    assert_equal(len(world.resources._device_revisions), 0)

    world.resources._device_revisions[offset_id] = _revision[Offset](world)
    world.reuse_device_copies(False)
    assert_false(world.resources._reuse_device)
    assert_equal(len(world.resources._device_revisions), 0)


def test_disabled_transfers_unchanged() raises:
    """Uploads every resource on every run while reuse is disabled.

    Raises:
        Error: If a disabled world skips an upload.
    """
    comptime if has_accelerator():
        var world = _world()
        for _ in range(3):
            assert_equal(_run_sum(world), full_upload)
            assert_equal(world._last_device_upload.segments, 3)
            _check_rows(world, 11)
        world.reuse_device_copies(True)
        _ = _run_sum(world)
        assert_equal(_run_sum(world), 0)
        world.reuse_device_copies(False)
        assert_equal(_run_sum(world), full_upload)
        assert_equal(_run_sum(world), full_upload)


def test_unchanged_runs_skip_uploads() raises:
    """Uploads unchanged resources once; read accessors keep copies current.

    Raises:
        Error: If an unchanged resource is uploaded again or results differ.
    """
    comptime if has_accelerator():
        var world = _world()
        world.reuse_device_copies(True)
        assert_equal(_run_sum(world), full_upload)
        for _ in range(12):
            assert_equal(_run_sum(world), 0)
            assert_equal(world._last_device_upload.segments, 0)
            _check_rows(world, 11)
        assert_equal(world.resources.read[Offset]().value, 10)
        assert_equal(_run_sum(world), 0)


def _mutate[path: Int](mut world: World[Int32]) raises -> Int32:
    """Applies one revision-advancing mutation.

    Parameters:
        path: Mutation path index.

    Args:
        world: World to mutate.

    Raises:
        Error: If the mutation fails.

    Returns:
        The row value the next `sum_kernel` run must produce.
    """
    comptime if path == 0:
        world.resources.set(Offset(30))
        return 31
    elif path == 1:
        world.resources.set[add_if_not_found=True](Offset(30))
        return 31
    elif path == 2:
        world.resources.get[Offset]().value = 30
        return 31
    elif path == 3:
        world.resources.get[Samples]().samples[0] = 5
        return 15
    elif path == 4:
        world.resources.get[Samples]() = _samples(7)
        return 17
    elif path == 5:
        var context = SystemContext(world)
        context.run[host_write_offset]()
        return 21
    elif path == 6:
        var context = SystemContext(world)
        context.run[host_read_write_offset]()
        return 12
    elif path == 7:
        world.resources.remove[Offset]()
        world.resources.add(Offset(30))
        return 31
    else:
        var replacement = ResourceStorage()
        replacement.add(_samples(2), Offset(30))
        replacement._set_reuse_device(True)
        world.resources = replacement^
        return 32


def _check_stale_path[path: Int]() raises:
    """Checks that one mutation path refreshes the next device run.

    Parameters:
        path: Mutation path index.

    Raises:
        Error: If the device run reads a stale copy.
    """
    var world = _world()
    world.reuse_device_copies(True)
    _ = _run_sum(world)
    assert_equal(_run_sum(world), 0)
    var expected = _mutate[path](world)
    assert_true(_run_sum(world) > 0)
    _check_rows(world, expected)
    assert_equal(_run_sum(world), 0)


def test_each_mutation_refreshes_device_copy() raises:
    """Runs one stale-copy check per revision-advancing operation.

    Raises:
        Error: If any path leaves a stale device copy.
    """
    comptime if has_accelerator():
        comptime for path in range(9):
            _check_stale_path[path]()


def test_device_writes_stamp_copies() raises:
    """Reuses a device-written resource after its successful download.

    Raises:
        Error: If the written copy is uploaded again or values are lost.
    """
    comptime if has_accelerator():
        var world = World[Int32]()
        world.resources.add(Counter(0))
        _ = world.storage.add_entities(Int32(0), count=5)
        world.reuse_device_copies(True)
        var context = SystemContext(world)
        var revision = _revision[Counter](world)
        context.run[count_kernel, on_device=True]()
        assert_equal(world._last_device_upload.bytes, size_of[Int32]())
        assert_true(_revision[Counter](world) > revision)
        context.run[count_kernel, on_device=True]()
        assert_equal(world._last_device_upload.bytes, 0)
        assert_equal(world.resources.read[Counter]().value, 2)
        _check_rows(world, 2)


def test_escaped_pointer_needs_invalidation() raises:
    """Raw-pointer writes stay invisible until the device copy is invalidated.

    Raises:
        Error: If invalidation does not refresh the device copy.
    """
    comptime if has_accelerator():
        var world = _world()
        world.reuse_device_copies(True)
        var offset = Pointer(to=world.resources.get[Offset]())
        _ = _run_sum(world)
        offset[].value = 40
        assert_equal(_run_sum(world), 0)
        _check_rows(world, 11)
        world.resources.invalidate_device[Offset]()
        assert_equal(_run_sum(world), size_of[Int32]())
        _check_rows(world, 41)

        offset[].value = 50
        world.invalidate_device_copies()
        assert_equal(_run_sum(world), full_upload)
        _check_rows(world, 51)


def test_failure_after_upload_reuploads() raises:
    """Marks a copy unknown when preparation fails after uploading it.

    Raises:
        Error: If the retry skips the partially prepared copy.
    """
    comptime if has_accelerator():
        var world = World[Int32]()
        world.resources.add(Flaky([Int32(3)], False))
        _ = world.storage.add_entities(Int32(0), count=5)
        world.reuse_device_copies(True)
        var context = SystemContext(world)
        context.run[flaky_kernel, on_device=True]()
        _check_rows(world, 3)
        var flaky = Pointer(to=world.resources.get[Flaky]())
        flaky[].fail = True
        world.resources.invalidate_device[Flaky]()
        with assert_raises():
            context.run[flaky_kernel, on_device=True]()
        assert_false(world.resources._poisoned)
        flaky[].fail = False
        flaky[].samples[0] = 4
        context.run[flaky_kernel, on_device=True]()
        assert_true(world._last_device_upload.bytes > 0)
        _check_rows(world, 4)


def test_world_copies_upload_again() raises:
    """Starts world copies without device copy records.

    Raises:
        Error: If a copied world reuses the source world's records.
    """
    comptime if has_accelerator():
        var world = _world()
        world.reuse_device_copies(True)
        _ = _run_sum(world)
        var copied = world.copy()
        assert_equal(_run_sum(copied), full_upload)
        assert_equal(_run_sum(copied), 0)
        assert_equal(_run_sum(world), 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
