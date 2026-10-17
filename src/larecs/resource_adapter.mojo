"""Stateless read-only resource adapters and context-local allocation caches."""

from max.gpu.host import DeviceContext, DeviceBuffer, HostBuffer
from std.memory import unsafe_uninit_copy_n
from std.sys import size_of
from .resource_representation import _plain_device_value


@fieldwise_init
struct _TransferStats(Copyable, Defaultable, Equatable, Writable):
    """Counts host-to-device uploads queued by one invocation or cache call."""

    var bytes: Int
    var segments: Int

    def __init__(out self):
        """Creates an empty count."""
        self.bytes = 0
        self.segments = 0

    def record(mut self, bytes: Int):
        """Counts one queued upload.

        Args:
            bytes: Uploaded byte count.
        """
        self.bytes += bytes
        self.segments += 1

    def add(mut self, other: Self):
        """Accumulates another count.

        Args:
            other: Count to add.
        """
        self.bytes += other.bytes
        self.segments += other.segments

    def __eq__(self, other: Self) -> Bool:
        """Compares byte and segment counts.

        Args:
            other: Count to compare with.

        Returns:
            Whether both counts are equal.
        """
        return self.bytes == other.bytes and self.segments == other.segments


@fieldwise_init
struct _Download(Movable):
    """Owns native staging bytes and their eventual publication address."""

    var staging: HostBuffer[DType.uint8]
    var target: Pointer[UInt8, MutUntrackedOrigin]


struct _TransferFrame(Movable):
    """Stages queue IO in native owned buffers; publishes only after completion.

    Native buffer release is ordered after queued uses on its context stream.
    Managed queued copies never reference caller-owned host memory.
    """

    var context: DeviceContext
    var downloads: List[_Download]
    var uploaded: _TransferStats
    """Uploads queued through this frame, including adapter cache uploads."""

    def __init__(out self, context: DeviceContext):
        """Creates an empty frame without queueing work.

        Args:
            context: The invocation's device queue.
        """
        self.context = context
        self.downloads = List[_Download]()
        self.uploaded = _TransferStats()

    def upload[
        origin: ImmOrigin
    ](
        mut self,
        buffer: DeviceBuffer[DType.uint8],
        source: Pointer[UInt8, origin],
    ) raises:
        """Snapshots host bytes before queueing their upload.

        Parameters:
            origin: The source borrow origin.

        Args:
            buffer: Exact destination range.
            source: Host bytes covering that range.

        Raises:
            Error: If native staging allocation or transfer fails.
        """
        if len(buffer) == 0:
            return
        var staging = self.context.enqueue_create_host_buffer[DType.uint8](
            len(buffer)
        )
        unsafe_uninit_copy_n[overlapping=False](
            dest=staging.unsafe_ptr(), src=source, count=len(buffer)
        )
        buffer.enqueue_copy_from(staging)
        self.uploaded.record(len(buffer))

    def download(
        mut self,
        buffer: DeviceBuffer[DType.uint8],
        target: Pointer[UInt8, MutUntrackedOrigin],
    ) raises:
        """Queues a download into owned staging without changing host values.

        Args:
            buffer: Exact source range.
            target: Host address valid until synchronous invocation completion.

        Raises:
            Error: If staging allocation or transfer fails.
        """
        if len(buffer) == 0:
            return
        var staging = self.context.enqueue_create_host_buffer[DType.uint8](
            len(buffer)
        )
        buffer.enqueue_copy_to(staging)
        self.downloads.append(_Download(staging^, target))

    def publish(mut self):
        """Copies completed staging into host values after successful synchronization.
        """
        for i in range(len(self.downloads)):
            ref item = self.downloads[i]
            unsafe_uninit_copy_n[overlapping=False](
                dest=item.target,
                src=item.staging.unsafe_ptr(),
                count=len(item.staging),
            )
        self.downloads.clear()


struct ResourceDeviceCache(Movable):
    """Reuses allocations for one source type on one world's device queue.

    Adapter uploads must use this cache's snapshotting helper. A slot identifies
    one contiguous allocation; nonnegative slots belong to the adapter. Slot -1
    is reserved by Larecs for the view descriptor. Contents are refreshed on
    every run unless the world reuses device copies (decision 0021) and the
    source is unchanged; then Larecs skips preparation entirely.
    """

    var context: DeviceContext
    var _buffers: Dict[Int, DeviceBuffer[DType.uint8]]
    var _uploaded: _TransferStats
    """Uploads since Larecs last collected them into an invocation frame."""

    def __init__(out self, context: DeviceContext):
        """Creates an empty cache without allocating device buffers.

        Args:
            context: The device queue owning all subsequent allocations.
        """
        self.context = context
        self._buffers = Dict[Int, DeviceBuffer[DType.uint8]]()
        self._uploaded = _TransferStats()

    def upload[
        mut: Bool, origin: Origin[mut=mut], //, T: TrivialRegisterPassable
    ](mut self, slot: Int, samples: Span[T, origin]) raises -> Pointer[
        T, ImmUntrackedOrigin
    ]:
        """Snapshots and uploads a contiguous sample buffer, reusing capacity.

        Parameters:
            mut: Source span mutability.
            origin: Source span borrow origin.
            T: Trivial sample element type.

        Args:
            slot: Nonnegative adapter allocation identifier.
            samples: Current source contents, uploaded on every call.

        Raises:
            Error: If the slot or byte count is invalid, or allocation/transfer fails.

        Returns:
            Immutable device pointer valid while this cache is leased.
            Empty spans receive a valid allocation but must not be dereferenced.
        """
        comptime assert _plain_device_value[
            T
        ](), "Resource samples require pointer-free trivial values"
        if slot < 0 or len(samples) > 9223372036854775807 // max(
            1, size_of[T]()
        ):
            raise Error("Invalid resource buffer slot or byte count")
        var buffer = self._ensure(slot, max(1, len(samples) * size_of[T]()))
        if len(samples) > 0 and size_of[T]() > 0:
            var frame = _TransferFrame(self.context)
            frame.upload(
                buffer.create_sub_buffer[DType.uint8](
                    0, len(samples) * size_of[T]()
                ),
                samples.unsafe_ptr()
                .unsafe_bitcast[UInt8]()
                .unsafe_mut_cast[False](),
            )
            self._uploaded.add(frame.uploaded)
        return Pointer[T, ImmUntrackedOrigin](
            unsafe_from_address=Int(buffer.unsafe_ptr())
        )

    def _ensure(
        mut self, slot: Int, bytes: Int
    ) raises -> DeviceBuffer[DType.uint8]:
        """Ensures capacity for one allocation slot.

        Args:
            slot: Internal allocation identifier.
            bytes: Required positive allocation size.

        Raises:
            Error: If allocation fails.

        Returns:
            The cached native buffer handle.
        """
        if slot not in self._buffers or len(self._buffers[slot]) < bytes:
            self._buffers[slot] = self.context.enqueue_create_buffer[
                DType.uint8
            ](bytes)
        return self._buffers[slot]

    def _descriptor[
        T: TrivialRegisterPassable
    ](mut self, view: T) raises -> DeviceBuffer[DType.uint8]:
        """Uploads one invocation's view into the reserved descriptor allocation.

        Parameters:
            T: Validated descriptor type.

        Args:
            view: Current descriptor containing device-local pointers.

        Raises:
            Error: If allocation or upload fails.

        Returns:
            The device descriptor buffer.
        """
        var buffer = self._ensure(-1, max(1, size_of[T]()))
        if size_of[T]() > 0:
            var frame = _TransferFrame(self.context)
            frame.upload(
                buffer.create_sub_buffer[DType.uint8](0, size_of[T]()),
                Pointer(to=view).unsafe_bitcast[UInt8](),
            )
            self._uploaded.add(frame.uploaded)
        return buffer


trait ResourceAdapter:
    """Stateless operations over the current source; no factory or adapter instance.

    Views and their pointers must not escape a synchronous invocation.
    Every view must support concurrent reads on its execution target, including
    view methods and all reachable data, without hidden unsafe mutation. No
    alias may mutate, resize, relocate, or free backing data before completion.
    The adapter author guarantees this; descriptor checks cannot prove it.
    Device preparation must upload through ResourceDeviceCache, never enqueue
    a copy from an external host pointer. Validation must neither mutate nor queue work.
    """

    comptime Source: Copyable & Deinitable
    comptime View: TrivialRegisterPassable

    @staticmethod
    def validate(source: Self.Source) raises:
        """Checks all source invariants before preparation.

        Args:
            source: Current authoritative host source.

        Raises:
            Error: If the source cannot produce a valid view.
        """
        ...

    @staticmethod
    def bind_host(source: Self.Source) raises -> Self.View:
        """Borrows current host samples in a portable descriptor.

        Args:
            source: Current validated source retained throughout execution.

        Raises:
            Error: If descriptor construction fails.

        Returns:
            Read-only host-local view.
        """
        ...

    @staticmethod
    def prepare_device(
        source: Self.Source, mut cache: ResourceDeviceCache
    ) raises -> Self.View:
        """Uploads current source samples and returns their device-local descriptor.

        Args:
            source: Current validated source.
            cache: Exclusively leased allocation cache for this source type.

        Raises:
            Error: If preparation or upload fails.

        Returns:
            Read-only device-local view.
        """
        ...


trait DevicePassableResource(Copyable, Deinitable):
    """Opt-in owning resource with one kernel representation on both targets."""

    comptime KernelView: TrivialRegisterPassable
    comptime Adapter: ResourceAdapter


@fieldwise_init
struct ReadBuffer[dtype: DType](Sized, TrivialRegisterPassable):
    """Portable immutable contiguous scalar view.

    Parameters:
        dtype: Scalar sample datatype.
    """

    var _pointer: Pointer[Scalar[Self.dtype], ImmUntrackedOrigin]
    var _length: Int

    def __len__(self) -> Int:
        """Returns the number of samples.

        Returns:
            Current logical length.
        """
        return self._length

    def __getitem__(self, index: Int) -> Scalar[Self.dtype]:
        """Reads one sample within the logical bounds.

        Args:
            index: Zero-based sample offset.

        Returns:
            The requested scalar value.
        """
        assert 0 <= index < self._length, "Resource sample index out of bounds"
        return self._pointer[unsafe_offset=index]


@fieldwise_init
struct BufferResource[dtype: DType](DevicePassableResource):
    """Owns host samples exposed through ReadBuffer on host and device.

    Parameters:
        dtype: Scalar sample datatype.
    """

    comptime KernelView = ReadBuffer[Self.dtype]
    comptime Adapter = BufferResourceAdapter[Self.dtype]
    var samples: List[Scalar[Self.dtype]]


struct BufferResourceAdapter[dtype: DType](ResourceAdapter):
    """Stateless adapter for a contiguous scalar BufferResource.

    Parameters:
        dtype: Scalar sample datatype.
    """

    comptime Source = BufferResource[Self.dtype]
    comptime View = ReadBuffer[Self.dtype]

    @staticmethod
    def validate(source: Self.Source) raises:
        """Validates scalar storage before preparation.

        Args:
            source: Current host sample owner.

        Raises:
            Error: If the byte count overflows the supported address range.
        """
        if (
            len(source.samples)
            > 9223372036854775807 // size_of[Scalar[Self.dtype]]()
        ):
            raise Error("Resource sample byte count overflow")

    @staticmethod
    def bind_host(source: Self.Source) raises -> Self.View:
        """Builds an immutable descriptor borrowing host samples.

        Args:
            source: Validated host sample owner.

        Raises:
            Error: If descriptor construction fails.

        Returns:
            Portable view over host samples.
        """
        return {
            Pointer[Scalar[Self.dtype], ImmUntrackedOrigin](
                unsafe_from_address=Int(source.samples.unsafe_ptr())
            ),
            len(source.samples),
        }

    @staticmethod
    def prepare_device(
        source: Self.Source, mut cache: ResourceDeviceCache
    ) raises -> Self.View:
        """Uploads the current samples and constructs a device descriptor.

        Args:
            source: Validated host sample owner.
            cache: Context-local exclusively leased cache.

        Raises:
            Error: If allocation or upload fails.

        Returns:
            Portable view over device samples.
        """
        return {
            cache.upload[Scalar[Self.dtype]](0, Span(source.samples)),
            len(source.samples),
        }
