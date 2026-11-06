"""Device-side storage for components and resources.

Provides `DeviceComponentStorage`, which mirrors a set of component columns
on the device, and `DeviceResourceStorage`, which uploads individual
resources for a kernel invocation.
"""

from max.gpu.host import DeviceBuffer, DeviceContext, DevicePointer
from std.sys import size_of
from std.memory import ArcPointer

from tracy import Zone

from .component import ComponentType, ComponentManager
from .debug_utils import debug_warn
from .gpu_launch import max_resident_blocks
from .resource import ResourceType, Resources
from .resource_adapter import _TransferFrame
from .resource_representation import _plain_device_value


@fieldwise_init
struct _Segment(Copyable, Equatable, ImplicitlyCopyable):
    """One contiguous store range at a fixed offset of a device column."""

    var store: Int
    """Index of the physical store."""
    var incarnation: UInt64
    """Identity of the store object; 0 never matches."""
    var revision: UInt64
    """Column revision the device bytes match."""
    var first_row: Int
    """First store row of the range."""
    var row_count: Int
    """Number of rows in the range."""
    var offset: Int
    """First device column row of the range."""

    def __eq__(self, other: Self) -> Bool:
        """Compares every field.

        Args:
            other: Segment to compare with.

        Returns:
            Whether both segments describe the same device bytes.
        """
        return (
            self.store == other.store
            and self.incarnation == other.incarnation
            and self.revision == other.revision
            and self.first_row == other.first_row
            and self.row_count == other.row_count
            and self.offset == other.offset
        )


struct DeviceComponentStorage[*ComponentTypes: ComponentType](Copyable):
    """Owns one byte-addressed device column per configured component type.

    Each initialized column has an independent valid row count. Its buffer
    length is a byte capacity, at least the row count times the component
    size. Capacity and valid row counts never shrink; smaller uploads
    overwrite only their range and retain previously valid suffix rows.

    Parameters:
        ComponentTypes: The component types managed by this storage.
    """

    comptime component_manager = ComponentManager[*Self.ComponentTypes]
    """The component manager assigning IDs to `ComponentTypes`."""

    comptime Columns = Array[
        Optional[DeviceBuffer[DType.uint8]], len(Self.ComponentTypes)
    ]
    """The type of the per-component device column array."""
    var _columns: Self.Columns
    var _lengths: Array[Int, len(Self.ComponentTypes)]
    """Valid rows per column; zero until uploaded or ensured for kernel output."""
    var _initial_capacity: Int
    """Minimum row capacity when a column is first allocated."""
    var _device_context: DeviceContext
    var _records: List[List[_Segment]]
    """Per component ID, the segments the device column holds (decision 0021).

    Only maintained while `_reuse` is enabled. A device run takes the
    records of every column it accesses and restores them only after
    successful publication, so a failure leaves those columns unknown.
    """
    var _reuse: Bool
    """Whether device runs may skip uploading unchanged segments."""
    var _host_id: Optional[ArcPointer[UInt8]]
    """Identity of the host storage the records describe."""
    var _max_grid_dim: Int
    """Maximum number of blocks a kernel launch on this device should use.

    ``0`` if the device does not report the attributes needed to compute it.
    """

    def __init__(
        out self,
        var device_context: DeviceContext,
        length: Int,
    ):
        """Creates storage with lazily allocated component columns.

        Args:
            device_context: The device context to allocate columns on.
            length: The initial row capacity of each column, allocated lazily.
                This reserves space but does not establish valid rows.
        """
        with Zone(
            function_name=(
                "DeviceComponentStorage.__init__(var device_context:"
                " DeviceContext, length: Int)"
            )
        ):
            self._columns = Self.Columns(fill=None)
            self._max_grid_dim = max_resident_blocks(device_context)
            self._device_context = device_context^
            self._lengths = Array[Int, len(Self.ComponentTypes)](fill=0)
            self._initial_capacity = max(0, length)
            self._records = Self._empty_records()
            self._reuse = False
            self._host_id = None

    def __init__(out self, *, copy: Self):
        """Copies the device storage from another instance.

        Args:
            copy: The device storage to copy.
        """
        with Zone(
            function_name="DeviceComponentStorage.__init__(*, copy: Self)"
        ):
            self._columns = Self.Columns(fill=None)
            self._device_context = copy._device_context
            self._lengths = copy._lengths.copy()
            self._initial_capacity = copy._initial_capacity
            self._max_grid_dim = copy._max_grid_dim
            self._records = Self._empty_records()
            self._reuse = copy._reuse
            self._host_id = None

            comptime for i in range(len(Self.ComponentTypes)):
                comptime T = Self.ComponentTypes[i]
                if copy._columns[i] is not None:
                    # `Copyable.__init__(out self, *, copy: Self)` cannot
                    # itself be `raises` (its trait signature isn't), so a
                    # device allocation/copy failure here can only be
                    # swallowed, not propagated to the caller -- unlike the
                    # `raises` constructors used everywhere else in this
                    # file. Swallowing it *silently* previously left
                    # `self._columns[i] = None` with no signal at all, so a
                    # copy could look complete while quietly missing data a
                    # caller relied on. `debug_warn` at least surfaces which
                    # column was dropped and why, in debug builds; see
                    # `LockGuard.__deinit__` in lock.mojo
                    # for the same pattern applied to the same constraint.
                    try:
                        self._create_column[T](
                            len(copy._columns[i].unsafe_value())
                        )
                        self._copy_column[T](copy._columns[i].unsafe_value())
                    except e:
                        self._columns[i] = None
                        self._lengths[i] = 0
                        debug_warn(
                            t"DeviceComponentStorage.copy: failed to copy"
                            t" the device column for"
                            t" {reflect[T].name()}: {String(e)}"
                        )

    @staticmethod
    def _empty_records() -> List[List[_Segment]]:
        """Creates one empty record list per component type.

        Returns:
            Records describing no device bytes.
        """
        var records = List[List[_Segment]](capacity=len(Self.ComponentTypes))
        for _ in range(len(Self.ComponentTypes)):
            records.append(List[_Segment]())
        return records^

    def _set_reuse(mut self, enabled: Bool):
        """Enables or disables segment reuse; disabling discards records.

        Args:
            enabled: Whether device runs may skip unchanged segments.
        """
        self._reuse = enabled
        if not enabled:
            self._invalidate_records()

    def _invalidate_records(mut self):
        """Marks every device column's contents unknown."""
        for i in range(len(self._records)):
            self._records[i].clear()

    def _check_host(mut self, host_id: ArcPointer[UInt8]):
        """Discards all records if they describe a different host storage.

        Args:
            host_id: Identity of the world's current host storage.
        """
        if (
            self._host_id is None
            or self._host_id.unsafe_value().unsafe_ptr() != host_id.unsafe_ptr()
        ):
            self._invalidate_records()
            self._host_id = host_id.copy()

    def _take_records[T: ComponentType](mut self) -> List[_Segment]:
        """Removes and returns the records of one column before queueing work.

        Parameters:
            T: The column's component type.

        Returns:
            The previous records; the column is unknown until restored.
        """
        comptime id = Self.component_manager.get_id[T]()
        var records = self._records[id].copy()
        self._records[id].clear()
        return records^

    def _restore_records[
        T: ComponentType
    ](mut self, var records: List[_Segment]):
        """Records the segments a column holds after a successful run.

        Parameters:
            T: The column's component type.

        Args:
            records: Segments in transfer order.
        """
        comptime id = Self.component_manager.get_id[T]()
        if self._reuse:
            self._records[id] = records^

    def has_component[T: ComponentType](self) -> Bool:
        """Returns whether the device column for ``T`` is initialized.

        Parameters:
            T: The component type to check.

        Returns:
            ``True`` when the component has an initialized device column.
        """
        with Zone(
            function_name=(
                "DeviceComponentStorage.has_component[T: ComponentType]()"
            )
        ):
            comptime assert Self.component_manager.contains_components[
                T
            ](), "Component type not in component manager"
            comptime id = Self.component_manager.get_id[T]()
            return Bool(self._columns[id])

    def _create_column[T: ComponentType](mut self, capacity_bytes: Int) raises:
        """Allocates a column with the requested byte capacity.

        Parameters:
            T: The component type to allocate.

        Args:
            capacity_bytes: The byte capacity of the new column.

        Raises:
            Error: If device allocation fails.
        """
        with Zone(
            function_name=(
                "DeviceComponentStorage._create_column[T: ComponentType]()"
            )
        ):
            comptime id = Self.component_manager.get_id[T]()

            self._columns[id] = self._device_context.enqueue_create_buffer[
                DType.uint8
            ](capacity_bytes)

    def _copy_column[
        T: ComponentType
    ](mut self, src: DeviceBuffer[DType.uint8]) raises:
        """Copies the valid prefix of an initialized column.

        Parameters:
            T: The component type to copy.

        Args:
            src: The source column with at least the valid row count.

        Raises:
            Error: If the destination is missing or the device copy fails.
        """
        with Zone(
            function_name=(
                "DeviceComponentStorage._copy_column[T: ComponentType](src:"
                " DeviceBuffer[DType.uint8])"
            )
        ):
            comptime id = Self.component_manager.get_id[T]()

            if self._columns[id] is None:
                raise Error("Column not initialized")

            var size = self._lengths[id] * size_of[T]()
            if size > 0:
                self._columns[id].unsafe_value().create_sub_buffer[DType.uint8](
                    0, size
                ).enqueue_copy_from(src.create_sub_buffer[DType.uint8](0, size))

    def copy_to_host[T: ComponentType](self, out data: List[T]) raises:
        """Copies the device column for ``T`` into a newly allocated list.

        Parameters:
            T: The component type of the column to copy.

        Returns:
            The output list ``data`` containing the valid column contents, or
            an empty list when the column is not initialized.

        Raises:
            Error: If synchronizing the device context fails.
        """
        with Zone(
            function_name=(
                "DeviceComponentStorage.copy_to_host[T: ComponentType](out"
                " data: List[T])"
            )
        ):
            comptime id = Self.component_manager.get_id[T]()

            if self._columns[id] is None:
                return List[T](capacity=0)

            data = List[T](unsafe_uninit_length=self._lengths[id])
            if self._lengths[id] > 0:
                self._columns[id].unsafe_value().create_sub_buffer[DType.uint8](
                    0, self._lengths[id] * size_of[T]()
                ).enqueue_copy_to(data.unsafe_ptr().unsafe_bitcast[UInt8]())
            self._device_context.synchronize()

    def copy_to_host[
        T: ComponentType
    ](
        self,
        column_ptr: Pointer[T, MutUntrackedOrigin],
        *,
        offset: Int = 0,
        length: Int = -1,
    ) raises:
        """Copies a range of the device column for ``T`` into host memory.

        Parameters:
            T: The component type of the column to copy.

        Args:
            column_ptr: The host pointer to copy the range into.
            offset: The starting row of the range to copy.
            length: The number of rows to copy. A negative value (the
                default) copies every row from ``offset`` through the end
                of the column.

        Raises:
            Error: If ``offset``/``length`` describe a range outside the
                selected column's valid row bounds, or if the device
                copy fails.
        """
        with Zone(
            function_name=(
                "DeviceComponentStorage.copy_to_host[T:"
                " ComponentType](column_ptr: Pointer[T, MutUntrackedOrigin], *,"
                " offset: Int, length: Int)"
            )
        ):
            comptime id = Self.component_manager.get_id[T]()

            if self._columns[id] is None:
                return

            # `length=-1` is a sentinel, not a literal count: it means "the
            # rest of the column from `offset`". Resolve it before
            # validating, so a bad explicit `length` (negative, or past the
            # column's end) is still rejected below rather than silently
            # multiplying out to a nonsensical byte count in
            # `create_sub_buffer`.
            var copy_length = (
                length if length >= 0 else self._lengths[id] - offset
            )

            var end = offset + copy_length
            if offset < 0 or copy_length < 0 or end > self._lengths[id]:
                raise Error(
                    t"DeviceComponentStorage.copy_to_host: range [{offset},"
                    t" {end}) is out of bounds for a column of length"
                    t" {self._lengths[id]}"
                )

            if copy_length == 0:
                return

            self._columns[id].unsafe_value().create_sub_buffer[DType.uint8](
                offset * size_of[T](), copy_length * size_of[T]()
            ).enqueue_copy_to(column_ptr.unsafe_bitcast[UInt8]())

    def ensure_column[T: ComponentType](mut self, length: Int) raises:
        """Ensures the device column for ``T`` exists and covers ``length`` rows.

        Creates or grows the column as needed, but uploads no data into it.
        Marks at least ``length`` rows valid for kernel output; the caller
        must write newly exposed rows before downloading them. Existing
        valid rows and capacity are retained when ``length`` is smaller.
        Used for a kernel component that is write-only for the current
        call: the column must exist before the kernel writes through it,
        but nothing needs uploading first, since a write-only component's
        prior value is never read by the kernel.

        Parameters:
            T: The component type of the column to ensure.

        Args:
            length: The minimum number of rows the column must cover.

        Raises:
            Error: If length is negative or device allocation fails.
        """
        with Zone(
            function_name=(
                "DeviceComponentStorage.ensure_column[T:"
                " ComponentType](length: Int)"
            )
        ):
            comptime id = Self.component_manager.get_id[T]()

            if length < 0:
                raise Error("Column length must be nonnegative")

            self.reserve_column[T](length)
            self._lengths[id] = max(self._lengths[id], length)

    def reserve_column[T: ComponentType](mut self, length: Int) raises:
        """Reserves device capacity without publishing unwritten logical rows.

        Existing valid rows survive growth. A new column allocates at least
        the initial capacity or requested rows; subsequent growth doubles
        byte capacity unless the request is larger. Smaller requests retain
        both capacity and valid length. Use ``ensure_column`` instead when
        promising output rows that a kernel will write.

        Parameters:
            T: The component type whose capacity to reserve.

        Args:
            length: The minimum row capacity, which must be nonnegative.

        Raises:
            Error: If length is negative or device allocation or copying fails.
        """
        comptime id = Self.component_manager.get_id[T]()
        if length < 0:
            raise Error("Column capacity must be nonnegative")

        var capacity_bytes = max(self._initial_capacity, length) * size_of[T]()
        if self._columns[id] is None:
            self._create_column[T](capacity_bytes)
        elif len(self._columns[id].unsafe_value()) < capacity_bytes:
            var old_buffer = self._columns[id].unsafe_value()
            capacity_bytes = max(capacity_bytes, 2 * len(old_buffer))
            var new_buffer = self._device_context.enqueue_create_buffer[
                DType.uint8
            ](capacity_bytes)
            var valid_bytes = self._lengths[id] * size_of[T]()
            if valid_bytes > 0:
                new_buffer.create_sub_buffer[DType.uint8](
                    0, valid_bytes
                ).enqueue_copy_from(
                    old_buffer.create_sub_buffer[DType.uint8](0, valid_bytes)
                )
            self._columns[id] = {new_buffer^}

    def copy_from_host[
        mut: Bool, origin: Origin[mut=mut], //, T: ComponentType
    ](mut self, data: Span[T, origin], *, offset: Int = 0) raises:
        """Copies host data for ``T`` into the device column, growing it if needed.

        Parameters:
            mut: Whether the source span is mutable.
            origin: The origin of the source span.
            T: The component type of the column to copy into.

        Args:
            data: The host data to upload.
            offset: The starting row at which to write the data. Must be in
                ``[0, valid rows]``; uploads may overwrite or append, but
                cannot leave an uninitialized gap. Smaller uploads retain
                the valid suffix. Empty uploads do not initialize a column.

        Raises:
            Error: If offset is outside the valid rows or allocating or copying
                the device buffer fails.
        """
        with Zone(
            function_name=(
                "DeviceComponentStorage.copy_from_host[mut: Bool, origin:"
                " Origin[mut=mut], //, T: ComponentType](data: Span[T,"
                " origin], *, offset: Int)"
            )
        ):
            comptime id = Self.component_manager.get_id[T]()

            if offset < 0 or offset > self._lengths[id]:
                raise Error("Upload offset is outside the column's valid rows")
            if len(data) == 0:
                return

            var old_length = self._lengths[id]
            self.reserve_column[T](len(data) + offset)

            var sub_buffer = (
                self._columns[id]
                .unsafe_value()
                .create_sub_buffer[DType.uint8](
                    offset * size_of[T](), len(data) * size_of[T]()
                )
            )
            sub_buffer.enqueue_copy_from(
                data.unsafe_ptr().unsafe_bitcast[UInt8]()
            )
            self._lengths[id] = max(old_length, offset + len(data))

    def stage_from_host[
        mut: Bool, origin: Origin[mut=mut], //, T: ComponentType
    ](
        mut self,
        mut frame: _TransferFrame,
        data: Span[T, origin],
        *,
        offset: Int = 0,
    ) raises:
        """Snapshots a host column range into native staging for queued upload.

        Parameters:
            mut: Source span mutability.
            origin: Source borrow origin.
            T: Component type.

        Args:
            frame: Invocation staging owner.
            data: Source component range.
            offset: First destination row.

        Raises:
            Error: If allocation or transfer fails.
        """
        if len(data) == 0:
            return
        self.ensure_column[T](len(data) + offset)
        comptime id = Self.component_manager.get_id[T]()
        frame.upload(
            self._columns[id]
            .unsafe_value()
            .create_sub_buffer[DType.uint8](
                offset * size_of[T](), len(data) * size_of[T]()
            ),
            data.unsafe_ptr().unsafe_bitcast[UInt8]().unsafe_mut_cast[False](),
        )

    def stage_to_host[
        T: ComponentType
    ](
        self,
        mut frame: _TransferFrame,
        column_ptr: Pointer[T, MutUntrackedOrigin],
        *,
        offset: Int = 0,
        length: Int = -1,
    ) raises:
        """Stages a device column range without publishing partial downloads.

        Parameters:
            T: Component type.

        Args:
            frame: Invocation staging and publication owner.
            column_ptr: Destination host component range.
            offset: First device source row.
            length: Row count, or -1 for the remaining column.

        Raises:
            Error: If the range is invalid or the transfer fails.
        """
        comptime id = Self.component_manager.get_id[T]()
        var count = length if length >= 0 else self._lengths[id] - offset
        if offset < 0 or count < 0 or count > self._lengths[id] - offset:
            raise Error("Invalid staged component download range")
        frame.download(
            self._columns[id]
            .unsafe_value()
            .create_sub_buffer[DType.uint8](
                offset * size_of[T](), count * size_of[T]()
            ),
            column_ptr.unsafe_bitcast[UInt8](),
        )

    def get_device_ptr[
        T: ComponentType
    ](mut self) raises -> DevicePointer[
        mut=True, DType.uint8, MutUntrackedOrigin
    ]:
        """Returns the device pointer to the column for ``T``.

        Parameters:
            T: The component type of the column to get.

        Returns:
            The device pointer to the component's column.

        Raises:
            Error: If the component's column is not initialized.
        """
        with Zone(
            function_name=(
                "DeviceComponentStorage.get_device_ptr[T: ComponentType]()"
            )
        ):
            comptime id = Self.component_manager.get_id[T]()
            if self._columns[id] is None:
                raise Error("Column not initialized")
            return rebind[
                DevicePointer[mut=True, DType.uint8, MutUntrackedOrigin]
            ](self._columns[id].unsafe_value().device_ptr())

    def synchronize(self) raises:
        """Blocks until all enqueued device operations have completed.

        Raises:
            Error: If synchronizing the device context fails.
        """
        with Zone(function_name="DeviceComponentStorage.synchronize()"):
            self._device_context.synchronize()


struct DeviceResourceStorage[resources: Resources](Copyable):
    """Owns one byte-addressed device buffer per resource type required by
    a kernel.

    Mirrors [.DeviceComponentStorage], but keyed by position in ``resources`` instead
    of by a [..component.ComponentManager]-assigned id: each kernel invocation uploads
    exactly the (small, fixed) set of resources it declared as required,
    rather than mirroring the whole resource table to the device.

    Parameters:
        resources: The resource types this storage may hold buffers for.
    """

    comptime Buffers = Array[
        Optional[DeviceBuffer[DType.uint8]], len(Self.resources)
    ]
    """The type of the per-resource device buffer array."""
    var _buffers: Self.Buffers
    var _device_context: DeviceContext

    def __init__(out self, var device_context: DeviceContext):
        """Creates a device resource storage with no buffers uploaded yet.

        Args:
            device_context: The device context to allocate buffers on.
        """
        with Zone(
            function_name=(
                "DeviceResourceStorage.__init__(var device_context:"
                " DeviceContext)"
            )
        ):
            self._buffers = Self.Buffers(fill=None)
            self._device_context = device_context^

    def upload[T: ResourceType](mut self, ref value: T) raises:
        """Copies ``value`` into a freshly allocated device buffer.

        The host value must remain alive until the queued copy completes.
        This copies only the value's bytes, not any allocations it points to.

        Parameters:
            T: The type of the resource to upload. Must be part of
                ``resources``.

        Args:
            value: The host-side resource value to copy to the device.

        Raises:
            Error: If allocating or copying the device buffer fails.
        """
        with Zone(
            function_name=(
                "DeviceResourceStorage.upload[T: ResourceType](ref value: T)"
            )
        ):
            comptime assert _plain_device_value[
                T
            ](), "Device resources require pointer-free trivial plain values"
            comptime id = Self.resources.index_of[T]()
            comptime assert id != -1, "T is not part of `resources`"

            self._buffers[id] = self._device_context.enqueue_create_buffer[
                DType.uint8
            ](size_of[T]())
            self._buffers[id].unsafe_value().enqueue_copy_from(
                Pointer(to=value).unsafe_bitcast[UInt8]()
            )

    def download[T: ResourceType](self, mut value: T) raises:
        """Copies the device buffer for ``T`` back into ``value``.

        Mirrors [.upload], but in the opposite direction: after a kernel
        that may have mutated the resource has run, this pulls its bytes
        back from the device buffer into the host-side value.

        Parameters:
            T: The type of the resource to download. Must have been
                [.DeviceResourceStorage.upload]ed already.

        Args:
            value: The host-side resource value to overwrite with the
                device buffer's contents.

        Raises:
            Error: If the resource has not been uploaded.
        """
        with Zone(
            function_name=(
                "DeviceResourceStorage.download[T: ResourceType](mut value: T)"
            )
        ):
            comptime assert _plain_device_value[
                T
            ](), "Device resources require pointer-free trivial plain values"
            comptime id = Self.resources.index_of[T]()
            comptime assert id != -1, "T is not part of `resources`"

            if self._buffers[id] is None:
                raise Error("Resource not uploaded: " + reflect[T].name())

            self._buffers[id].unsafe_value().enqueue_copy_to(
                Pointer(to=value).unsafe_bitcast[UInt8]()
            )

    def get_device_ptr[
        T: ResourceType
    ](self) raises -> DevicePointer[mut=True, DType.uint8, MutUntrackedOrigin]:
        """Returns the device pointer backing resource ``T``.

        Parameters:
            T: The type of the resource to look up. Must have been
                [.DeviceResourceStorage.upload]ed already.

        Raises:
            Error: If the resource has not been uploaded.

        Returns:
            A device pointer to the uploaded resource's bytes.
        """
        with Zone(
            function_name=(
                "DeviceResourceStorage.get_device_ptr[T: ResourceType]()"
            )
        ):
            comptime assert _plain_device_value[
                T
            ](), "Device resources require pointer-free trivial plain values"
            comptime id = Self.resources.index_of[T]()
            comptime assert id != -1, "T is not part of `resources`"

            if self._buffers[id] is None:
                raise Error("Resource not uploaded: " + reflect[T].name())

            return rebind[
                DevicePointer[mut=True, DType.uint8, MutUntrackedOrigin]
            ](self._buffers[id].unsafe_value().device_ptr())

    def synchronize(self) raises:
        """Blocks until all enqueued device operations have completed.

        Raises:
            Error: If synchronizing the device context fails.
        """
        with Zone(function_name="DeviceResourceStorage.synchronize()"):
            self._device_context.synchronize()
