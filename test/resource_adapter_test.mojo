# SKIP_ASAN
# SKIP_DEBUG

from std.testing import *
from std.sys import has_accelerator
from larecs import (
    World,
    SystemContext,
    KernelContext,
    Filter,
    Resources,
    BufferResource,
    ReadBuffer,
    ResourceType,
    DevicePassableResource,
    ResourceAdapter,
    ResourceDeviceCache,
    EntityRange,
)
from larecs.resource import (
    ResourceStorage,
    _ResourceInvocation,
    _drain_failed_device,
)
from larecs.resource_adapter import _TransferFrame
from max.gpu.host import DeviceContext
from std.sys import size_of

comptime Samples = BufferResource[DType.int32]
comptime sample_spec = Resources().read[Samples]()


def sample_kernel(
    context: KernelContext[Filter().include[Int32](), sample_spec]
):
    """Adds the first sample and logical length to every matching component.

    Args:
        context: Matching rows and the portable sample view.
    """
    ref samples = context.resources.get[Samples]()
    var increment = Int32(len(samples))
    if len(samples) > 0:
        increment += samples[0]
    for entity in context:
        entity.get[Int32]() += increment


def test_portable_buffer_host_device_host() raises:
    """Runs one kernel over current host samples and cached device samples.

    Raises:
        Error: If execution or sample ownership checks fail.
    """
    var world = World[Int32]()
    world.resources.add(Samples([Int32(7), Int32(8)]))
    _ = world.storage.add_entities(Int32(1), count=5)
    var context = SystemContext(world)
    context.run[sample_kernel]()
    comptime if has_accelerator():
        context.run[sample_kernel, on_device=True]()
    else:
        context.run[sample_kernel]()
    context.run[sample_kernel]()
    assert_equal(world.resources.get[Samples]().samples[0], 7)
    for entity in world.storage.query[Filter().include[Int32]()]():
        assert_equal(entity.get[Int32](), 28)


@fieldwise_init
struct GridView(TrivialRegisterPassable):
    """Scientific descriptor with immutable samples and current metadata."""

    var samples: Pointer[Int32, ImmUntrackedOrigin]
    var width: Int
    var height: Int
    var maximum: Int32


struct Grid(DevicePassableResource):
    """Host owner used to test current scientific configuration and replacement.
    """

    comptime KernelView = GridView
    comptime Adapter = GridAdapter
    var samples: List[Int32]
    var width: Int
    var height: Int
    var maximum: Int32
    var fail_prepare: Bool

    def __init__(
        out self,
        var samples: List[Int32],
        width: Int,
        height: Int,
        maximum: Int32,
        fail_prepare: Bool = False,
    ):
        """Constructs the current scientific source.

        Args:
            samples: Owned sample values.
            width: Grid width.
            height: Grid height.
            maximum: Scientific metadata.
            fail_prepare: Whether to inject a post-upload failure.
        """
        self.samples = samples^
        self.width = width
        self.height = height
        self.maximum = maximum
        self.fail_prepare = fail_prepare


struct GridAdapter(ResourceAdapter):
    """Stateless adapter validating dimensions before queueing any work."""

    comptime Source = Grid
    comptime View = GridView

    @staticmethod
    def validate(source: Self.Source) raises:
        """Checks shape arithmetic and exact sample count.

        Args:
            source: Current scientific source.

        Raises:
            Error: If dimensions overflow or do not match sample storage.
        """
        if source.width < 0 or source.height < 0:
            raise Error("Negative grid dimensions")
        if (
            source.height != 0
            and source.width > 9223372036854775807 // source.height
        ):
            raise Error("Grid dimension overflow")
        if source.width * source.height != len(source.samples):
            raise Error("Grid sample count mismatch")

    @staticmethod
    def bind_host(source: Self.Source) raises -> Self.View:
        """Builds the current host descriptor.

        Args:
            source: Validated current source.

        Raises:
            Error: If preparation fails.

        Returns:
            Descriptor borrowing immutable host samples.
        """
        return {
            Pointer[Int32, ImmUntrackedOrigin](
                unsafe_from_address=Int(source.samples.unsafe_ptr())
            ),
            source.width,
            source.height,
            source.maximum,
        }

    @staticmethod
    def prepare_device(
        source: Self.Source, mut cache: ResourceDeviceCache
    ) raises -> Self.View:
        """Uploads samples and optionally fails after enqueue for cleanup testing.

        Args:
            source: Validated current source.
            cache: Leased source-type buffer cache.

        Raises:
            Error: If upload fails or failure injection is enabled.

        Returns:
            Current descriptor over uploaded samples.
        """
        var pointer = cache.upload[Int32](0, Span(source.samples))
        if source.fail_prepare:
            raise Error("Injected failure after resource upload")
        return {pointer, source.width, source.height, source.maximum}


@fieldwise_init
struct OtherGrid(DevicePassableResource):
    """A distinct source deliberately sharing GridView."""

    comptime KernelView = GridView
    comptime Adapter = OtherGridAdapter
    var grid: Grid


struct OtherGridAdapter(ResourceAdapter):
    """Forwards preparation while preserving separate source identity."""

    comptime Source = OtherGrid
    comptime View = GridView

    @staticmethod
    def validate(source: Self.Source) raises:
        """Validates the wrapped grid.

        Args:
            source: Current wrapper.

        Raises:
            Error: If the wrapped grid is invalid.
        """
        GridAdapter.validate(source.grid)

    @staticmethod
    def bind_host(source: Self.Source) raises -> Self.View:
        """Borrows the wrapped host grid.

        Args:
            source: Validated wrapper.

        Raises:
            Error: If preparation fails.

        Returns:
            Portable host grid view.
        """
        return GridAdapter.bind_host(source.grid)

    @staticmethod
    def prepare_device(
        source: Self.Source, mut cache: ResourceDeviceCache
    ) raises -> Self.View:
        """Uploads the wrapped grid in its separate source cache.

        Args:
            source: Validated wrapper.
            cache: Separate source-type cache.

        Raises:
            Error: If preparation fails.

        Returns:
            Portable device grid view.
        """
        return GridAdapter.prepare_device(source.grid, cache)


comptime grids = Resources().read[Grid, OtherGrid]()


def grid_kernel(context: KernelContext[Filter().include[Int32](), grids]):
    """Uses current metadata and samples from two sources with the same view.

    Args:
        context: Matching rows and source-oriented views.
    """
    ref a = context.resources.get[Grid]()
    ref b = context.resources.get[OtherGrid]()
    var delta = a.maximum + b.maximum + Int32(a.width + a.height)
    if a.width * a.height > 0:
        delta += a.samples[unsafe_offset=a.width * a.height - 1]
    if b.width * b.height > 0:
        delta += b.samples[]
    for entity in context:
        entity.get[Int32]() += delta


def _check_rows(mut world: World[Int32], expected: Int32) raises:
    """Checks all component outputs outside execution.

    Args:
        world: Authoritative host world.
        expected: Required component value.

    Raises:
        Error: If any row differs.
    """
    for entity in world.storage.query[Filter().include[Int32]()]():
        assert_equal(entity.get[Int32](), expected)


def _run_grid[device: Bool](mut world: World[Int32]) raises:
    """Runs the identical scientific kernel on the chosen backend.

    Parameters:
        device: Whether GPU execution is requested.

    Args:
        world: Validated host world.

    Raises:
        Error: If execution fails.
    """
    var context = SystemContext(world)
    context.run[grid_kernel, on_device=device]()


def _check_grid_updates[device: Bool]() raises:
    """Checks edits, assignment replacement, capacity reuse, and world copies.

    Parameters:
        device: Backend under test.

    Raises:
        Error: If ownership, cache, or result checks fail.
    """
    var world = World[Int32]()
    world.resources.add(Grid([Int32(1), Int32(2)], 2, 1, 10))
    world.resources.set[add_if_not_found=True](
        OtherGrid(Grid([Int32(3)], 1, 1, 20))
    )
    _ = world.storage.add_entities(Int32(0), count=7)
    _run_grid[device](world)
    _check_rows(world, 38)
    assert_false(world.resources.has[GridView]())
    world.resources.get[Grid]().maximum = 11
    world.resources.get[Grid]().samples[1] = 4
    _run_grid[device](world)
    _check_rows(world, 79)
    world.resources.get[Grid]() = Grid(
        [Int32(2), Int32(4), Int32(6), Int32(8)], 2, 2, 30
    )
    _run_grid[device](world)
    _check_rows(world, 144)
    var capacity = 0
    var allocation = 0
    comptime if device and has_accelerator():
        ref cache = world.resources._device_cache[reflect[Grid].name()]
        capacity = len(cache._buffers[0])
        allocation = Int(cache._buffers[0].unsafe_ptr())
    world.resources.get[Grid]() = Grid([Int32(5)], 1, 1, 40)
    _run_grid[device](world)
    _check_rows(world, 214)
    comptime if device and has_accelerator():
        ref cache = world.resources._device_cache[reflect[Grid].name()]
        assert_equal(len(cache._buffers[0]), capacity)
        assert_equal(Int(cache._buffers[0].unsafe_ptr()), allocation)
    var copied = world.copy()
    assert_equal(len(copied.resources._device_cache), 0)
    copied.resources.get[Grid]().samples[0] = 9
    _run_grid[device](copied)
    _check_rows(copied, 288)
    assert_equal(world.resources.get[Grid]().samples[0], 5)
    _check_rows(world, 214)
    world.resources.get[Grid]() = Grid(List[Int32](), 0, 0, 50)
    _run_grid[device](world)
    _check_rows(world, 287)
    world.resources.remove[Grid]()
    assert_false(reflect[Grid].name() in world.resources._device_cache)
    assert_false(reflect[Grid].name() in world.resources._bindings)


def test_grid_updates_host() raises:
    """Checks current source semantics on CPU.

    Raises:
        Error: If ownership or result checks fail.
    """
    _check_grid_updates[False]()


def test_grid_updates_device() raises:
    """Checks current source semantics on the actual accelerator.

    Raises:
        Error: If ownership or result checks fail.
    """
    comptime if has_accelerator():
        _check_grid_updates[True]()


def test_validation_and_leases() raises:
    """Rejects invalid sources and reentrant source operations before preparation.

    Raises:
        Error: If a validation or lease guard fails.
    """
    var world = World[Int32]()
    world.resources.add(
        Grid([Int32(1)], 2, 2, 0), OtherGrid(Grid(List[Int32](), 0, 0, 0))
    )
    var context = SystemContext(world)
    with assert_raises():
        context.run[grid_kernel]()
    comptime if has_accelerator():
        with assert_raises():
            context.run[grid_kernel, on_device=True]()
    assert_equal(len(world.resources._device_cache), 0)
    world.resources.set(Grid([Int32(1)], 1, 1, 0))
    var escaped = Pointer[ResourceStorage, MutUntrackedOrigin](
        unsafe_from_address=Int(Pointer(to=world.resources))
    )
    var binding = _ResourceInvocation[grids, origin_of(world.resources)](
        world.resources
    )
    with assert_raises():
        _ = escaped[].get[Grid]()
    with assert_raises():
        escaped[].set(Grid([Int32(2)], 1, 1, 0))
    with assert_raises():
        escaped[].remove[Grid]()
    with assert_raises():
        var nested = _ResourceInvocation[grids, MutUntrackedOrigin](escaped[])
        nested.release()
    binding.release()
    assert_equal(world.resources.get[Grid]().samples[0], 1)
    comptime if has_accelerator():
        context.run[grid_kernel, on_device=True]()
    assert_equal(len(world.resources._device_cache), 0)


def test_failure_after_upload_and_retry() raises:
    """Drains an adapter failure and safely retries with refreshed source data.

    Raises:
        Error: If a failure publishes outputs or prevents safe retry.
    """
    comptime if has_accelerator():
        var world = World[Int32]()
        world.resources.add(
            Grid([Int32(1)], 1, 1, 0, True),
            OtherGrid(Grid([Int32(3)], 1, 1, 0)),
        )
        _ = world.storage.add_entities(Int32(0), count=9)
        with assert_raises():
            _run_grid[True](world)
        assert_false(world.resources._poisoned)
        _check_rows(world, 0)
        world.resources.get[Grid]().samples[0] = 7
        world.resources.get[Grid]().fail_prepare = False
        _run_grid[True](world)
        _check_rows(world, 12)


def test_staged_download_publication() raises:
    """Keeps CPU outputs unchanged until successful completion and publication.

    Raises:
        Error: If staging exposes partial output or publication fails.
    """
    comptime if has_accelerator():
        var context = DeviceContext()
        var frame = _TransferFrame(context)
        var buffer = context.enqueue_create_buffer[DType.uint8](1)
        var output: UInt8 = 3
        buffer.enqueue_fill(9)
        frame.download(
            buffer,
            Pointer[UInt8, MutUntrackedOrigin](
                unsafe_from_address=Int(Pointer(to=output))
            ),
        )
        context.synchronize()
        assert_equal(output, 3)
        frame.publish()
        assert_equal(output, 9)


def test_selected_portable_views() raises:
    """Uses the source-oriented API for packed disjoint device row selections.

    Raises:
        Error: If unselected rows change or selected rows see a wrong view.
    """
    var world = World[Int32]()
    world.resources.add(Samples([Int32(7), Int32(8)]))
    _ = world.storage.add_entities(Int32(1), count=6)
    var context = SystemContext(world)
    var selection = context._empty_selection()
    selection._ranges.append(EntityRange(1, 1, 1))
    selection._ranges.append(EntityRange(1, 4, 1))
    comptime if has_accelerator():
        selection.run[sample_kernel, on_device=True]()
    else:
        selection.run[sample_kernel]()
    selection^.release()
    var index = 0
    for entity in world.storage.query[Filter().include[Int32]()]():
        assert_equal(
            entity.get[Int32](), Int32(10 if index == 1 or index == 4 else 1)
        )
        index += 1


def _failed_completion(context: DeviceContext) raises:
    """Simulates failure to confirm completion without leaving real test work live.

    Args:
        context: Actual test queue, drained before injecting its reported failure.

    Raises:
        Error: Always reports a completion failure.
    """
    context.synchronize()
    raise Error("Injected completion failure")


def test_unknown_completion_poisoning() raises:
    """Rejects future host and device execution, even with no resource declarations.

    Raises:
        Error: If unconfirmed completion permits execution or loses error context.
    """
    comptime if has_accelerator():
        var world = World[Int32]()
        var context = SystemContext(world)
        var device_context = world._device_storage[]._device_context
        try:
            _drain_failed_device[_failed_completion](
                world.resources,
                device_context,
                Error("Injected operation failure"),
                world._execution_unusable,
            )
        except error:
            assert_true(String(error).find("Injected operation failure") >= 0)
            assert_true(String(error).find("Injected completion failure") >= 0)
        assert_true(world.resources._poisoned)

        def empty(rows: KernelContext[Filter().include[Int32]()]):
            """Provides an empty kernel to probe poisoned-world execution.

            Args:
                rows: Matching rows, deliberately unused.
            """
            pass

        with assert_raises():
            context.run[empty]()
        with assert_raises():
            context.run[empty, on_device=True]()
        # Replacing a public container cannot repair an unknown device queue.
        world.resources = ResourceStorage()
        assert_false(world.resources._poisoned)
        with assert_raises():
            context.run[empty]()
        with assert_raises():
            context.run[empty, on_device=True]()
        var selection = context._empty_selection()
        with assert_raises():
            selection.run[empty]()
        selection^.release()


def test_context_mismatch_preflight() raises:
    """Rejects cache reuse on another queue before further preparation.

    Raises:
        Error: If mismatched context preflight accepts the cache.
    """
    comptime if has_accelerator():
        var world = World[Int32]()
        world.resources.add(Samples([Int32(1)]))
        var other = DeviceContext()
        world.resources._device_cache[
            reflect[Samples].name()
        ] = ResourceDeviceCache(other)
        var binding = _ResourceInvocation[
            sample_spec, origin_of(world.resources)
        ](world.resources)
        var device_context = world._device_storage[]._device_context
        with assert_raises():
            binding.validate_device(device_context)
        binding.release()


@fieldwise_init
struct PlainRead(ResourceType):
    """Plain resource used to verify read access suppresses copy-back."""

    var value: Int32


def test_plain_read_skips_download() raises:
    """Stages no resource output for a read declaration, even if device bytes differ.

    Raises:
        Error: If a read binding downloads or publishes a device-only change.
    """
    comptime if has_accelerator():
        var world = World[Int32]()
        world.resources.add(PlainRead(3))
        var context = world._device_storage[]._device_context
        var frame = _TransferFrame(context)
        var binding = _ResourceInvocation[
            Resources().read[PlainRead](), origin_of(world.resources)
        ](world.resources)
        var pointers = binding.bind_device(context, frame)
        pointers[0].buffer().enqueue_fill(0)
        binding.download(frame)
        assert_equal(len(frame.downloads), 0)
        context.synchronize()
        frame.publish()
        binding.release()
        assert_equal(world.resources.get[PlainRead]().value, 3)


def main() raises:
    """Runs portable resource adapter integration checks.

    Raises:
        Error: If any test fails.
    """
    TestSuite.discover_tests[__functions_in_module()]().run()
