"""Stateless resource adapters, access modes, and context-local allocation caches."""

from max.gpu.host import DeviceContext, DeviceBuffer, HostBuffer
from std.memory import unsafe_uninit_copy_n
from std.sys import size_of
from .resource_representation import _plain_device_value


@fieldwise_init
struct ResourceAccess(Equatable, TrivialRegisterPassable, Writable):
    """Declared kernel access to one resource source.

    Adapted resources receive the full mode during mutable preparation, so they
    can distinguish fresh `WRITE` output from preserving `READ_WRITE` access.
    """

    var _value: Int

    comptime READ = ResourceAccess(1)
    """Immutable access; adapted sources select `View[False]`."""
    comptime WRITE = ResourceAccess(2)
    """Fresh output; adapted sources select `View[True]` over initialized output."""
    comptime READ_WRITE = ResourceAccess(3)
    """Mutable access preserving existing contents; selects `View[True]`."""

    def __eq__(self, other: Self) -> Bool:
        """Compares two access modes.

        Args:
            other: Mode to compare with.

        Returns:
            Whether both modes are equal.
        """
        return self._value == other._value

    def mutable(self) -> Bool:
        """Returns whether kernels may mutate the resource.

        Returns:
            True for `WRITE` and `READ_WRITE`.
        """
        return self._value != 1

    def preserves_contents(self) -> Bool:
        """Returns whether kernels observe the source's existing contents.

        Returns:
            True for `READ` and `READ_WRITE`; False for fresh `WRITE` output.
        """
        return self._value != 2

    def write_to(self, mut writer: Some[Writer]):
        """Writes the declaration name.

        Args:
            writer: Destination writer.
        """
        if self._value == 1:
            writer.write("read")
        elif self._value == 2:
            writer.write("write")
        else:
            writer.write("read_write")


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

    Adapter transfers must use this cache's staging helpers. A slot identifies
    one contiguous allocation; nonnegative slots belong to the adapter. Slot -1
    is reserved by Larecs for the view descriptor. Contents are refreshed on
    every run unless the world reuses device copies (decision 0021) and the
    source is unchanged; then Larecs skips preparation entirely. Mutable
    adapted resources are prepared on every run (decision 0022).
    """

    var context: DeviceContext
    var _buffers: Dict[Int, DeviceBuffer[DType.uint8]]
    var _uploaded: _TransferStats
    """Uploads since Larecs last collected them into an invocation frame."""
    var _downloads: List[_Download]
    """Staged downloads Larecs moves into the invocation frame for publication."""

    def __init__(out self, context: DeviceContext):
        """Creates an empty cache without allocating device buffers.

        Args:
            context: The device queue owning all subsequent allocations.
        """
        self.context = context
        self._buffers = Dict[Int, DeviceBuffer[DType.uint8]]()
        self._uploaded = _TransferStats()
        self._downloads = List[_Download]()

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
        return Pointer[T, ImmUntrackedOrigin](
            unsafe_from_address=self._upload(slot, samples)
        )

    def upload_mutable[
        mut: Bool, origin: Origin[mut=mut], //, T: TrivialRegisterPassable
    ](mut self, slot: Int, samples: Span[T, origin]) raises -> Pointer[
        T, MutUntrackedOrigin
    ]:
        """Uploads current contents into a buffer that mutable views may write.

        Use this for `READ_WRITE` preparation, which preserves existing contents.

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
            Mutable device pointer valid while this cache is leased. Kernel
            writes reach the host only through `download`.
        """
        return Pointer[T, MutUntrackedOrigin](
            unsafe_from_address=self._upload(slot, samples)
        )

    def fill[
        T: TrivialRegisterPassable
    ](mut self, slot: Int, count: Int, value: T) raises -> Pointer[
        T, MutUntrackedOrigin
    ]:
        """Initializes a mutable buffer with one value, ignoring host contents.

        Use this for fresh `WRITE` output instead of uploading stale source
        contents. The fill is snapshotted in staging and queued like an upload.

        Parameters:
            T: Trivial element type.

        Args:
            slot: Nonnegative adapter allocation identifier.
            count: Number of elements to initialize.
            value: Initial value of every element.

        Raises:
            Error: If the slot or count is invalid, or allocation/transfer fails.

        Returns:
            Mutable device pointer valid while this cache is leased.
        """
        comptime assert _plain_device_value[
            T
        ](), "Resource samples require pointer-free trivial values"
        if count < 0:
            raise Error("Invalid resource buffer element count")
        var values = List[T](length=count, fill=value)
        return Pointer[T, MutUntrackedOrigin](
            unsafe_from_address=self._upload(slot, Span(values))
        )

    def download[
        origin: MutOrigin, //, T: TrivialRegisterPassable
    ](mut self, slot: Int, target: Span[T, origin]) raises:
        """Stages a device buffer prefix for publication into host memory.

        The host target is written only after the invocation's queue completes
        successfully. Failed invocations discard staged bytes. The target must
        remain valid, unaliased, and unresized until the run returns.

        Parameters:
            origin: Mutable host target origin.
            T: Trivial element type.

        Args:
            slot: Previously prepared adapter allocation identifier.
            target: Host elements receiving the first `len(target)` device
                elements of the slot.

        Raises:
            Error: If the slot is missing or too small, or staging fails.
        """
        comptime assert _plain_device_value[
            T
        ](), "Resource samples require pointer-free trivial values"
        if slot < 0 or slot not in self._buffers:
            raise Error("Cannot download an unprepared resource buffer slot")
        var bytes = len(target) * size_of[T]()
        if bytes == 0:
            return
        if len(self._buffers[slot]) < bytes:
            raise Error("Resource download exceeds its device buffer")
        var staging = self.context.enqueue_create_host_buffer[DType.uint8](
            bytes
        )
        self._buffers[slot].create_sub_buffer[DType.uint8](
            0, bytes
        ).enqueue_copy_to(staging)
        self._downloads.append(
            _Download(
                staging^,
                Pointer[UInt8, MutUntrackedOrigin](
                    unsafe_from_address=Int(target.unsafe_ptr())
                ),
            )
        )

    def _upload[
        mut: Bool, origin: Origin[mut=mut], //, T: TrivialRegisterPassable
    ](mut self, slot: Int, samples: Span[T, origin]) raises -> Int:
        """Snapshots and uploads samples, returning the device address.

        Parameters:
            mut: Source span mutability.
            origin: Source span borrow origin.
            T: Trivial sample element type.

        Args:
            slot: Nonnegative adapter allocation identifier.
            samples: Contents to upload.

        Raises:
            Error: If the slot or byte count is invalid, or allocation/transfer fails.

        Returns:
            Address of the slot's device allocation.
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
        return Int(buffer.unsafe_ptr())

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

    `View[False]` is the read view and `View[True]` the mutable view; they may
    be distinct types. Descriptors are immutable trivial values: mutable views
    reach shared state through pointers into adapter-managed backing buffers.

    Views and their pointers must not escape a synchronous invocation.
    Every read view must support concurrent reads on its execution target,
    including view methods and all reachable data, without hidden unsafe
    mutation. No alias may mutate, resize, relocate, or free backing data before
    completion. The adapter author guarantees this; descriptor checks cannot
    prove it. Device preparation must transfer through ResourceDeviceCache,
    never enqueue a copy from an external host pointer. Validation must neither
    mutate nor queue work.

    Mutable access is opt-in. `supports_mutation` admits `write` and
    `read_write` declarations on sequential host execution. GPU and threaded
    host execution additionally require `supports_concurrent_mutation`, which
    the author may declare only if every mutable view operation is safe under
    concurrent use, for example through atomics or provably disjoint writes.
    Larecs's exclusive source lease does not prevent races among kernel
    workers; the user is responsible for safe resource access.
    """

    comptime Source: Copyable & Deinitable
    comptime View[mut: Bool]: TrivialRegisterPassable
    """Kernel descriptor selected by declared access.

    Parameters:
        mut: False for the read view, True for the mutable view.
    """
    comptime supports_mutation: Bool = False
    """Whether `write` and `read_write` declarations are supported."""
    comptime supports_concurrent_mutation: Bool = False
    """Whether mutable views are safe for concurrent GPU or threaded host use."""

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
    def bind_host(source: Self.Source) raises -> Self.View[False]:
        """Borrows current host samples in a portable read descriptor.

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
    ) raises -> Self.View[False]:
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

    @staticmethod
    def bind_host_mutable[
        access: ResourceAccess
    ](mut source: Self.Source) raises -> Self.View[True]:
        """Prepares host backing storage and returns a mutable descriptor.

        Called once per invocation before any kernel runs, even when no rows
        match. `WRITE` must initialize fresh output; `READ_WRITE` must
        preserve existing contents. Host kernels write backing storage
        directly, so a failed invocation is not rolled back.

        Parameters:
            access: `WRITE` or `READ_WRITE`.

        Args:
            source: Current validated source, leased throughout execution.

        Raises:
            Error: If preparation fails or mutation is unsupported.

        Returns:
            Mutable host-local view.
        """
        raise Error("Resource adapter does not support mutable host access")

    @staticmethod
    def prepare_device_mutable[
        access: ResourceAccess
    ](
        mut source: Self.Source, mut cache: ResourceDeviceCache
    ) raises -> Self.View[True]:
        """Prepares device backing buffers and returns a mutable descriptor.

        Called once per invocation with matching rows. `WRITE` must
        initialize fresh output, for example with `cache.fill`; `READ_WRITE`
        must upload existing contents, for example with `cache.upload_mutable`.

        Parameters:
            access: `WRITE` or `READ_WRITE`.

        Args:
            source: Current validated source, leased throughout execution.
            cache: Exclusively leased allocation cache for this source type.

        Raises:
            Error: If preparation fails or mutation is unsupported.

        Returns:
            Mutable device-local view.
        """
        raise Error("Resource adapter does not support mutable device access")

    @staticmethod
    def stage_device_results[
        access: ResourceAccess
    ](mut source: Self.Source, mut cache: ResourceDeviceCache) raises:
        """Stages device outputs for publication into the host source.

        Called after the kernel is queued. Use `cache.download` for every
        output; Larecs publishes staged bytes only after the queue completes.
        Resize host targets here, before staging, never afterwards.

        Parameters:
            access: `WRITE` or `READ_WRITE`.

        Args:
            source: Current source, leased throughout execution.
            cache: Cache holding the buffers prepared for this invocation.

        Raises:
            Error: If staging fails or mutation is unsupported.
        """
        raise Error("Resource adapter does not support mutable device access")

    @staticmethod
    def finalize[access: ResourceAccess](mut source: Self.Source) raises:
        """Completes adapter results after execution and publication.

        Called once per successful mutable invocation on either target, after
        all kernel work completed and device outputs were published, including
        invocations without matching rows. Raising reports an error but keeps
        published outputs.

        Parameters:
            access: `WRITE` or `READ_WRITE`.

        Args:
            source: Current source holding all published outputs.

        Raises:
            Error: If the adapter reports a result failure, such as overflow.
        """
        pass


trait DevicePassableResource(Copyable, Deinitable):
    """Opt-in owning resource with one kernel representation on both targets.

    `View[mut]` forwards to the adapter. `KernelView` is a compatibility alias
    for the read view, `View[False]`.
    """

    comptime Adapter: ResourceAdapter
    comptime View[mut: Bool]: TrivialRegisterPassable = Self.Adapter.View[mut]
    """Kernel descriptor selected by declared access.

    Parameters:
        mut: False for the read view, True for the mutable view.
    """
    comptime KernelView: TrivialRegisterPassable = Self.View[False]
    """Compatibility alias for the read view."""


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

    comptime Adapter = BufferResourceAdapter[Self.dtype]
    var samples: List[Scalar[Self.dtype]]


struct BufferResourceAdapter[dtype: DType](ResourceAdapter):
    """Stateless adapter for a contiguous scalar BufferResource.

    Parameters:
        dtype: Scalar sample datatype.
    """

    comptime Source = BufferResource[Self.dtype]
    comptime View[mut: Bool] = ReadBuffer[Self.dtype]

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
    def bind_host(source: Self.Source) raises -> Self.View[False]:
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
    ) raises -> Self.View[False]:
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
