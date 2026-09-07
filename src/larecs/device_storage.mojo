"""Device-side (GPU) storage for components and resources.

Provides `DeviceComponentStorage`, which mirrors a set of component columns
on the device, and `DeviceResourceStorage`, which uploads individual
resources for a kernel invocation.
"""

from max.gpu.host import DeviceBuffer, DeviceContext, DevicePointer
from std.sys import size_of

from tracy import Zone

from .component import ComponentType, ComponentManager
from .debug_utils import debug_warn
from .resource import ResourceType, Resources


@fieldwise_init
struct DeviceComponentType:
    """Describes the on-device layout of a component type."""

    var dtype: DType
    """The scalar data type used to represent the component's bytes."""
    var dtype_size: Int
    """The size of `dtype`, in bytes."""
    var size: Int
    """The size of the component type, in bytes."""
    var padding: Int
    """Extra bytes appended to `size` to satisfy alignment requirements."""


struct DeviceComponentStorage[*ComponentTypes: ComponentType](Copyable):
    """Owns one byte-addressed device column per configured component type.

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
    var _length: Int
    var _device_context: DeviceContext

    def __init__(
        out self,
        var device_context: DeviceContext,
        length: Int,
    ):
        """Allocates all configured device component columns.

        Args:
            device_context: The device context to allocate columns on.
            length: The number of rows each column should be sized for.
        """
        with Zone(
            function_name=(
                "DeviceComponentStorage.__init__(var device_context:"
                " DeviceContext, length: Int)"
            )
        ):
            self._columns = Self.Columns(fill=None)
            self._device_context = device_context^
            self._length = length

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
            self._length = copy._length

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
                        self._create_column[T]()
                        self._copy_column[T](copy._columns[i].unsafe_value())
                    except e:
                        self._columns[i] = None
                        debug_warn(
                            t"DeviceComponentStorage.copy: failed to copy"
                            t" the device column for"
                            t" {reflect[T].name()}: {String(e)}"
                        )

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

    def _create_column[T: ComponentType](mut self) raises:
        with Zone(
            function_name=(
                "DeviceComponentStorage._create_column[T: ComponentType]()"
            )
        ):
            comptime id = Self.component_manager.get_id[T]()

            self._columns[id] = self._device_context.enqueue_create_buffer[
                DType.uint8
            ](self._length * size_of[T]())

    def _copy_column[
        T: ComponentType
    ](mut self, src: DeviceBuffer[DType.uint8]) raises:
        with Zone(
            function_name=(
                "DeviceComponentStorage._copy_column[T: ComponentType](src:"
                " DeviceBuffer[DType.uint8])"
            )
        ):
            comptime id = Self.component_manager.get_id[T]()

            if self._columns[id] is None:
                raise Error("Column not initialized")

            assert len(self._columns[id].unsafe_value()) <= len(src)

            self._columns[id].unsafe_value().enqueue_copy_from(src)

    def copy_to_host[T: ComponentType](self, out data: List[T]) raises:
        """Copies the device column for ``T`` into a newly allocated list.

        Parameters:
            T: The component type of the column to copy.

        Returns:
            The column contents, or an empty list when the column is not initialized.

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

            # Build the result as a `List[T]` directly, sized in *elements*
            # (`self._length`), and copy into its raw bytes -- rather than
            # building a `List[UInt8]` sized in bytes and reinterpreting it
            # via `rebind_var[List[T]]`. `rebind_var` only reinterprets the
            # list's fields (pointer, length, capacity) bit-for-bit; it does
            # not rescale `length`/`capacity` from a byte count to an
            # element count, so the previous version left `data` reporting
            # `self._length * size_of[T]()` elements -- `size_of[T]()` times
            # too many -- for any `T` wider than one byte.
            data = List[T](unsafe_uninit_length=self._length)
            self._columns[id].unsafe_value().enqueue_copy_to(
                data.unsafe_ptr().unsafe_bitcast[UInt8]()
            )
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
                column's ``[0, self._length)`` bounds, or if the device
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
            var copy_length = length if length >= 0 else self._length - offset

            var end = offset + copy_length
            if offset < 0 or copy_length < 0 or end > self._length:
                raise Error(
                    t"DeviceComponentStorage.copy_to_host: range [{offset},"
                    t" {end}) is out of bounds for a column of length"
                    t" {self._length}"
                )

            self._columns[id].unsafe_value().create_sub_buffer[DType.uint8](
                offset * size_of[T](), copy_length * size_of[T]()
            ).enqueue_copy_to(column_ptr.unsafe_bitcast[UInt8]())

    def ensure_column[T: ComponentType](mut self, length: Int) raises:
        """Ensures the device column for ``T`` exists and covers ``length`` rows.

        Creates or grows the column as needed, but uploads no data into it.
        Used for a kernel component that is write-only for the current
        call: the column must exist before the kernel writes through it,
        but nothing needs uploading first, since a write-only component's
        prior value is never read by the kernel.

        Parameters:
            T: The component type of the column to ensure.

        Args:
            length: The minimum number of rows the column must cover.

        Raises:
            Error: If allocating or growing the device buffer fails.
        """
        with Zone(
            function_name=(
                "DeviceComponentStorage.ensure_column[T:"
                " ComponentType](length: Int)"
            )
        ):
            comptime id = Self.component_manager.get_id[T]()

            if self._length < length:
                self._length = length

            if self._columns[id] is None:
                self._columns[id] = {
                    self._device_context.enqueue_create_buffer[DType.uint8](
                        self._length * size_of[T]()
                    )
                }

            # Compare byte counts on both sides: `len()` on a `uint8`
            # `DeviceBuffer` is a byte count, while `self._length` is a row
            # count. Comparing them directly as if they were the same unit
            # made this condition true for any component wider than one
            # byte, so every call reallocated the column and did a full
            # device-to-device copy of the column it had just allocated,
            # even when the column's size had not actually changed.
            if (
                len(self._columns[id].unsafe_value())
                != self._length * size_of[T]()
            ):
                var old_buffer = self._columns[id].unsafe_value()
                var new_buffer = self._device_context.enqueue_create_buffer[
                    DType.uint8
                ](self._length * size_of[T]())
                # The device copy API requires the destination and source
                # buffers to be the same size (a same-sized `enqueue_copy_to`
                # or `enqueue_copy_from` errors as "not enough data in src"
                # or "Destination buffer size must be >= source buffer
                # size" otherwise). `new_buffer` is always at least as large
                # as `old_buffer` here, since this branch only ever grows a
                # column, so copy into a same-sized leading sub-buffer of
                # `new_buffer` rather than into `new_buffer` directly.
                new_buffer.create_sub_buffer[DType.uint8](
                    0, len(old_buffer)
                ).enqueue_copy_from(old_buffer)
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
            offset: The starting row at which to write the data.

        Raises:
            Error: If allocating or copying the device buffer fails.
        """
        with Zone(
            function_name=(
                "DeviceComponentStorage.copy_from_host[mut: Bool, origin:"
                " Origin[mut=mut], //, T: ComponentType](data: Span[T,"
                " origin], *, offset: Int)"
            )
        ):
            comptime id = Self.component_manager.get_id[T]()

            if len(data) == 0:
                return

            self.ensure_column[T](len(data) + offset)

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

        Takes ``value`` by `ref` and copies from it immediately, in the
        same call -- callers must pass the result of a resource lookup
        directly (e.g. ``device_resources.upload[T](world.resources.get[T]())``)
        rather than routing it through a variable that outlives the call,
        since a `ref` returned by a `raises` accessor is only guaranteed
        valid for immediate use at its own call site.

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
