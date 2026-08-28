from max.gpu.host import DeviceBuffer, DeviceContext, DevicePointer
from std.sys import size_of

from .component import ComponentType, ComponentManager


@fieldwise_init
struct DeviceComponentType:
    var dtype: DType
    var dtype_size: Int
    var size: Int
    var padding: Int


struct DeviceStorage[*ComponentTypes: ComponentType](Copyable):
    """Owns one byte-addressed device column per configured component type."""

    comptime component_manager = ComponentManager[*Self.ComponentTypes]

    comptime Columns = Array[
        Optional[DeviceBuffer[DType.uint8]], len(Self.ComponentTypes)
    ]
    var _columns: Self.Columns
    var _length: Int
    var _device_context: DeviceContext

    def __init__(
        out self,
        var device_context: DeviceContext,
        length: Int,
    ):
        """Allocates all configured device component columns."""
        self._columns = Self.Columns(fill=None)
        self._device_context = device_context^
        self._length = length

    def __init__(out self, *, copy: Self):
        """Copies the device storage from another instance."""
        self._columns = Self.Columns(fill=None)
        self._device_context = copy._device_context
        self._length = copy._length

        comptime for i in range(len(Self.ComponentTypes)):
            comptime T = Self.ComponentTypes[i]
            if copy._columns[i] is not None:
                try:
                    self._create_column[T]()
                    self._copy_column[T](copy._columns[i].unsafe_value())
                except:
                    self._columns[i] = None

    def has_component[T: ComponentType](self) -> Bool:
        """Returns whether the device column for ``T`` is initialized.

        Parameters:
            T: The component type to check.

        Returns:
            ``True`` when the component has an initialized device column.
        """
        comptime assert Self.component_manager.contains_components[
            T
        ](), "Component type not in component manager"
        comptime id = Self.component_manager.get_id[T]()
        return Bool(self._columns[id])

    def _create_column[T: ComponentType](mut self) raises:
        comptime id = Self.component_manager.get_id[T]()

        self._columns[id] = self._device_context.create_buffer_sync[
            DType.uint8
        ](self._length * size_of[T]())

    def _copy_column[
        T: ComponentType
    ](mut self, src: DeviceBuffer[DType.uint8]) raises:
        comptime id = Self.component_manager.get_id[T]()

        if self._columns[id] is None:
            raise "Column not initialized"

        assert len(self._columns[id].unsafe_value()) <= len(src)

        self._columns[id].unsafe_value().enqueue_copy_from(src)

    def copy_to_host[T: ComponentType](self, out data: List[T]) raises:
        comptime id = Self.component_manager.get_id[T]()

        if self._columns[id] is None:
            return List[T](capacity=0)

        var bytes = List[UInt8](length=self._length * size_of[T](), fill=0)
        self._columns[id].unsafe_value().enqueue_copy_to(bytes.unsafe_ptr())
        self._device_context.synchronize()
        data = rebind_var[List[T]](bytes^)

    def copy_to_host[
        T: ComponentType
    ](
        self,
        column_ptr: Pointer[T, MutUntrackedOrigin],
        *,
        offset: Int = 0,
        length: Int = -1,
    ) raises:
        comptime id = Self.component_manager.get_id[T]()

        if self._columns[id] is None:
            return

        self._columns[id].unsafe_value().create_sub_buffer[DType.uint8](
            offset * size_of[T](), length * size_of[T]()
        ).enqueue_copy_to(column_ptr.unsafe_bitcast[UInt8]())

    def copy_from_host[
        mut: Bool, origin: Origin[mut=mut], //, T: ComponentType
    ](mut self, data: Span[T, origin], *, offset: Int = 0) raises:
        comptime id = Self.component_manager.get_id[T]()

        if len(data) == 0:
            return

        if self._length <= (len(data) + offset):
            self._length = len(data) + offset

        if self._columns[id] is None:
            self._columns[id] = {
                self._device_context.create_buffer_sync[DType.uint8](
                    self._length * size_of[T]()
                )
            }

        if len(self._columns[id].unsafe_value()) != self._length:
            var new_buffer = self._device_context.create_buffer_sync[
                DType.uint8
            ](self._length * size_of[T]())
            self._columns[id].unsafe_value().enqueue_copy_to(new_buffer)
            self._columns[id] = {new_buffer^}

        var sub_buffer = (
            self._columns[id]
            .unsafe_value()
            .create_sub_buffer[DType.uint8](
                offset * size_of[T](), len(data) * size_of[T]()
            )
        )
        sub_buffer.enqueue_copy_from(data.unsafe_ptr().unsafe_bitcast[UInt8]())

    def get_device_ptr[
        T: ComponentType
    ](mut self) raises -> DevicePointer[
        mut=True, DType.uint8, MutUntrackedOrigin
    ]:
        comptime id = Self.component_manager.get_id[T]()
        if self._columns[id] is None:
            raise "Column not initialized"
        return rebind[DevicePointer[mut=True, DType.uint8, MutUntrackedOrigin]](
            self._columns[id].unsafe_value().device_ptr()
        )

    def synchronize(self) raises:
        self._device_context.synchronize()
