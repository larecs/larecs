"""Resource types and host-side resource storage.

Provides `Resources`, a compile-time list of resource types, and
`ResourceStorage`, which holds one instance of each resource by type.
"""

from std.collections.dict import Dict, DictKeyError
from std.reflection import reflect
from std.sys import size_of, align_of
from std.memory import (
    is_trivially_movable,
    is_trivially_copyable,
    is_trivially_deletable,
)

from max.gpu.host import DeviceBuffer, DeviceContext, DevicePointer

from tracy import Zone

from .unsafe_box import UnsafeBox

comptime ResourceType = Copyable & Deinitable
"""The trait that resources must conform to."""

comptime GPUResourceType = TrivialRegisterPassable
"""Legacy trait alias retained for compatibility.

GPU resource validation uses [.constrain_gpu_safe_resources] to check trivial
copy, move, and deletion instead of requiring conformance to this trait.
Resources must also contain only data valid on the device; these properties
alone do not make host pointers device-accessible.
"""


comptime Int32Dict = Dict[Int32, Int32]
"""Host integer dictionary used by ``Int32DictResource``."""

comptime StringDict = Dict[String, Int32]
"""Host string dictionary used by ``StringDictResource``."""


def _string_bucket[
    origin: Origin
](bytes: Span[UInt8, origin], capacity: Int) -> Int:
    """Hashes UTF-8 bytes into a power-of-two device table.

    Parameters:
        origin: The origin of the borrowed key bytes.

    Args:
        bytes: The UTF-8 key bytes.
        capacity: The table capacity, a power of two.

    Returns:
        The first bucket to probe.
    """
    var bucket = 0
    for i in range(len(bytes)):
        bucket = (bucket * 33 + Int(bytes[i])) & (capacity - 1)
    return bucket


@fieldwise_init
struct DeviceInt32Dict(TrivialRegisterPassable):
    """Read-only dictionary view over packed host or device buffers."""

    var keys: Pointer[Int32, MutUntrackedOrigin]
    var values: Pointer[Int32, MutUntrackedOrigin]
    var occupied: Pointer[UInt8, MutUntrackedOrigin]
    var capacity: Int

    def get_or(self, key: Int32, default: Int32) -> Int32:
        """Returns a value or the supplied default when the key is absent.

        Args:
            key: The key to find.
            default: The value returned for a missing key.

        Returns:
            The matching value or ``default``.
        """
        var slot = Int(key) & (self.capacity - 1)
        for _ in range(self.capacity):
            if self.occupied[unsafe_offset=slot] == 0:
                return default
            if self.keys[unsafe_offset=slot] == key:
                return self.values[unsafe_offset=slot]
            slot = (slot + 1) & (self.capacity - 1)
        return default


@fieldwise_init
struct DeviceStringDict(TrivialRegisterPassable):
    """Read-only string view over packed host or device UTF-8 bytes."""

    var offsets: Pointer[Int32, MutUntrackedOrigin]
    var lengths: Pointer[Int32, MutUntrackedOrigin]
    var values: Pointer[Int32, MutUntrackedOrigin]
    var occupied: Pointer[UInt8, MutUntrackedOrigin]
    var bytes: Pointer[UInt8, MutUntrackedOrigin]
    var capacity: Int

    def get_or[
        origin: Origin
    ](self, key: StringSlice[origin], default: Int32) -> Int32:
        """Returns a value for a UTF-8 key, or the supplied default.

        Parameters:
            origin: The origin of the borrowed key bytes.

        Args:
            key: A string slice whose bytes are accessible on this target.
            default: The value returned for a missing key.

        Returns:
            The matching value or ``default``.
        """
        var key_bytes = key.as_bytes()
        var slot = _string_bucket(key_bytes, self.capacity)
        for _ in range(self.capacity):
            if self.occupied[unsafe_offset=slot] == 0:
                return default
            if Int(self.lengths[unsafe_offset=slot]) == len(key_bytes):
                var matches = True
                var offset = Int(self.offsets[unsafe_offset=slot])
                for i in range(len(key_bytes)):
                    if self.bytes[unsafe_offset=offset + i] != key_bytes[i]:
                        matches = False
                        break
                if matches:
                    return self.values[unsafe_offset=slot]
            slot = (slot + 1) & (self.capacity - 1)
        return default


comptime Int32DictView = DeviceInt32Dict
"""A GPU-safe lookup view for an integer dictionary resource."""

comptime StringDictView = DeviceStringDict
"""A GPU-safe lookup view for a string dictionary resource."""


struct HostInt32DictTable(Movable):
    """Owns an integer dictionary table for a CPU kernel or GPU upload."""

    var keys: List[Int32]
    var values: List[Int32]
    var occupied: List[UInt8]
    var view: DeviceInt32Dict

    def __init__(out self, ref dictionary: Int32Dict):
        """Packs an integer dictionary into a read-only table.

        Args:
            dictionary: The host dictionary to pack.
        """
        var capacity = 8
        while capacity < len(dictionary) * 2:
            capacity *= 2
        self.keys = List[Int32](unsafe_uninit_length=capacity)
        self.values = List[Int32](unsafe_uninit_length=capacity)
        self.occupied = List[UInt8](unsafe_uninit_length=capacity)
        for slot in range(capacity):
            self.keys[slot] = 0
            self.values[slot] = 0
            self.occupied[slot] = 0
        for entry in dictionary.items():
            var slot = Int(entry.key) & (capacity - 1)
            while self.occupied[slot] != 0:
                slot = (slot + 1) & (capacity - 1)
            self.keys[slot] = entry.key
            self.values[slot] = entry.value
            self.occupied[slot] = 1
        self.view = DeviceInt32Dict(
            self.keys.unsafe_ptr().unsafe_origin_cast[MutUntrackedOrigin](),
            self.values.unsafe_ptr().unsafe_origin_cast[MutUntrackedOrigin](),
            self.occupied.unsafe_ptr().unsafe_origin_cast[MutUntrackedOrigin](),
            capacity,
        )


struct HostStringDictTable(Movable):
    """Owns a string dictionary table and its packed UTF-8 key bytes."""

    var offsets: List[Int32]
    var lengths: List[Int32]
    var values: List[Int32]
    var occupied: List[UInt8]
    var bytes: List[UInt8]
    var byte_length: Int
    var view: DeviceStringDict

    def __init__(out self, ref dictionary: StringDict) raises:
        """Packs a string dictionary into a read-only table.

        Args:
            dictionary: The host dictionary to pack.

        Raises:
            Error: If the packed UTF-8 bytes exceed the supported size.
        """
        var capacity = 8
        while capacity < len(dictionary) * 2:
            capacity *= 2
        self.offsets = List[Int32](unsafe_uninit_length=capacity)
        self.lengths = List[Int32](unsafe_uninit_length=capacity)
        self.values = List[Int32](unsafe_uninit_length=capacity)
        self.occupied = List[UInt8](unsafe_uninit_length=capacity)
        self.bytes = List[UInt8]()
        for slot in range(capacity):
            self.offsets[slot] = 0
            self.lengths[slot] = 0
            self.values[slot] = 0
            self.occupied[slot] = 0
        for entry in dictionary.items():
            var key_bytes = entry.key.as_bytes()
            var slot = _string_bucket(key_bytes, capacity)
            while self.occupied[slot] != 0:
                slot = (slot + 1) & (capacity - 1)
            if len(self.bytes) + len(key_bytes) > 2147483647:
                raise Error("StringDict key data exceeds 2 GiB")
            self.offsets[slot] = Int32(len(self.bytes))
            self.lengths[slot] = Int32(len(key_bytes))
            self.values[slot] = entry.value
            self.occupied[slot] = 1
            for i in range(len(key_bytes)):
                self.bytes.append(key_bytes[i])
        self.byte_length = len(self.bytes)
        if self.byte_length == 0:
            self.bytes.append(0)
        self.view = DeviceStringDict(
            self.offsets.unsafe_ptr().unsafe_origin_cast[MutUntrackedOrigin](),
            self.lengths.unsafe_ptr().unsafe_origin_cast[MutUntrackedOrigin](),
            self.values.unsafe_ptr().unsafe_origin_cast[MutUntrackedOrigin](),
            self.occupied.unsafe_ptr().unsafe_origin_cast[MutUntrackedOrigin](),
            self.bytes.unsafe_ptr().unsafe_origin_cast[MutUntrackedOrigin](),
            capacity,
        )


struct ResourceEncoder:
    """Encodes dictionary fields for CPU and GPU resource views."""

    var _int32_tables: List[HostInt32DictTable]
    var _string_tables: List[HostStringDictTable]
    var _views: List[List[UInt64]]
    var _device_buffers: List[DeviceBuffer[DType.uint8]]
    var _device_context: Optional[DeviceContext]

    def __init__(out self):
        """Creates empty per-invocation dictionary storage."""
        self._int32_tables = List[HostInt32DictTable]()
        self._string_tables = List[HostStringDictTable]()
        self._views = List[List[UInt64]]()
        self._device_buffers = List[DeviceBuffer[DType.uint8]]()
        self._device_context = None

    @staticmethod
    def for_device(device_context: DeviceContext) -> Self:
        """Creates an encoder that writes dictionary tables to a device.

        Args:
            device_context: The target GPU device context.

        Returns:
            An encoder owning its device-side table buffers.
        """
        var result = Self()
        result._device_context = device_context
        return result^

    def _copy_list[
        T: Copyable & Deinitable
    ](mut self, ref values: List[T]) raises -> Pointer[T, MutUntrackedOrigin]:
        """Uploads a packed table array and retains the device buffer.

        Parameters:
            T: The array element type.

        Args:
            values: The packed host array.

        Returns:
            A device pointer to the uploaded array.

        Raises:
            Error: If device allocation or transfer fails.
        """
        var buffer = self._device_context.unsafe_value().enqueue_create_buffer[
            DType.uint8
        ](len(values) * size_of[T]())
        buffer.enqueue_copy_from(values.unsafe_ptr().unsafe_bitcast[UInt8]())
        var pointer = (
            buffer.device_ptr()
            .buffer()
            .unsafe_ptr()
            .unsafe_bitcast[T]()
            .unsafe_origin_cast[MutUntrackedOrigin]()
        )
        self._device_buffers.append(buffer^)
        return pointer

    def pack_int32(
        mut self, ref dictionary: Int32Dict
    ) raises -> DeviceInt32Dict:
        """Encodes an integer dictionary field for the current target.

        Args:
            dictionary: The host dictionary field.

        Returns:
            A GPU-safe view, also valid for CPU kernels.

        Raises:
            Error: If device allocation or transfer fails.
        """
        var table = HostInt32DictTable(dictionary)
        if self._device_context:
            var view = DeviceInt32Dict(
                self._copy_list(table.keys),
                self._copy_list(table.values),
                self._copy_list(table.occupied),
                table.view.capacity,
            )
            self._int32_tables.append(table^)
            return view
        self._int32_tables.append(table^)
        return self._int32_tables[len(self._int32_tables) - 1].view

    def pack_string(
        mut self, ref dictionary: StringDict
    ) raises -> DeviceStringDict:
        """Encodes a string dictionary field for the current target.

        Args:
            dictionary: The host dictionary field.

        Returns:
            A GPU-safe view, also valid for CPU kernels.

        Raises:
            Error: If packing, device allocation, or transfer fails.
        """
        var table = HostStringDictTable(dictionary)
        if self._device_context:
            var view = DeviceStringDict(
                self._copy_list(table.offsets),
                self._copy_list(table.lengths),
                self._copy_list(table.values),
                self._copy_list(table.occupied),
                self._copy_list(table.bytes),
                table.view.capacity,
            )
            self._string_tables.append(table^)
            return view
        self._string_tables.append(table^)
        return self._string_tables[len(self._string_tables) - 1].view

    def store_view[
        T: TrivialRegisterPassable
    ](mut self, ref view: T) -> Pointer[UInt8, MutUntrackedOrigin]:
        """Retains a converted CPU resource view through a kernel call.

        Parameters:
            T: The trivial view type.

        Args:
            view: The view to retain.

        Returns:
            A pointer to the retained view bytes.
        """
        comptime assert (
            align_of[T]() <= align_of[UInt64]()
        ), "GPUResource view alignment must be at most 8 bytes"
        var words = List[UInt64](unsafe_uninit_length=(size_of[T]() + 7) // 8)
        var src = Pointer(to=view).unsafe_bitcast[UInt8]()
        var dst = words.unsafe_ptr().unsafe_bitcast[UInt8]()
        for i in range(size_of[T]()):
            dst[unsafe_offset=i] = src[unsafe_offset=i]
        self._views.append(words^)
        return (
            self._views[len(self._views) - 1]
            .unsafe_ptr()
            .unsafe_bitcast[UInt8]()
            .unsafe_origin_cast[MutUntrackedOrigin]()
        )

    def keep_alive(self) -> Int:
        """Keeps backing arrays live through the last CPU kernel call.

        Returns:
            The total number of allocated table slots.
        """
        var count = 0
        for i in range(len(self._int32_tables)):
            count += len(self._int32_tables[i].keys)
        for i in range(len(self._string_tables)):
            count += len(self._string_tables[i].offsets)
        count += len(self._views)
        return count


trait GPUResource(ResourceType):
    """A resource with an explicit GPU-safe, currently read-only kernel view.

    Kernel view mutations are not decoded into the host resource after a run.
    """

    comptime ViewType: TrivialRegisterPassable

    def encode(self, mut encoder: ResourceEncoder) raises -> Self.ViewType:
        """Builds a kernel view from this host resource.

        Args:
            encoder: Owns transferred dictionary tables and view buffers.

        Returns:
            A GPU-safe view of this resource.

        Raises:
            Error: If conversion or transfer fails.
        """
        ...


struct Int32DictResource(GPUResource):
    """Host integer dictionary exposed as a GPU-safe kernel view."""

    comptime ViewType = DeviceInt32Dict
    var entries: Int32Dict

    def __init__(out self):
        """Creates an empty integer dictionary resource."""
        self.entries = Int32Dict()

    def encode(self, mut encoder: ResourceEncoder) raises -> DeviceInt32Dict:
        """Encodes this dictionary for a CPU or GPU kernel.

        Args:
            encoder: Owns the packed dictionary table.

        Returns:
            A GPU-safe integer lookup view.

        Raises:
            Error: If device allocation or transfer fails.
        """
        return encoder.pack_int32(self.entries)


struct StringDictResource(GPUResource):
    """Host string dictionary exposed as a GPU-safe kernel view."""

    comptime ViewType = DeviceStringDict
    var entries: StringDict

    def __init__(out self):
        """Creates an empty string dictionary resource."""
        self.entries = StringDict()

    def encode(self, mut encoder: ResourceEncoder) raises -> DeviceStringDict:
        """Encodes this dictionary for a CPU or GPU kernel.

        Args:
            encoder: Owns the packed dictionary table.

        Returns:
            A GPU-safe string lookup view.

        Raises:
            Error: If packing or device transfer fails.
        """
        return encoder.pack_string(self.entries)


struct KernelResourceView[T: ResourceType]:
    """Selects the type returned by a kernel resource accessor."""

    comptime Type = (
        Self.T.ViewType if conforms_to(Self.T, GPUResource) else Self.T
    )


def constrain_gpu_safe_resources[*Ts: ResourceType]() -> Bool:
    """Checks whether every resource has a supported GPU transfer path.

    Parameters:
        Ts: The resource types to check.

    Returns:
        True when every type in ``Ts`` has trivial copy, move, and deletion,
        or implements ``GPUResource``.
    """
    with Zone(
        function_name=(
            "resource.constrain_gpu_safe_resources[*Ts: ResourceType]()"
        )
    ):
        comptime for i in range(len(Ts)):
            comptime if not conforms_to(Ts[i], GPUResource):
                comptime if not (
                    is_trivially_movable[Ts[i]]()
                    and is_trivially_copyable[Ts[i]]()
                    and is_trivially_deletable[Ts[i]]()
                ):
                    return False
        return True


@fieldwise_init
struct Resources[*ResourceTypes: ResourceType](Sized):
    """A compile-time list of resource types.

    Parameters:
        ResourceTypes: The listed resource types.
    """

    def __len__(self) -> Int:
        """Returns the number of component types included by the filter.

        Returns:
            The number of resource types.
        """
        with Zone(function_name="Resources.__len__()"):
            return len(self.ResourceTypes)

    @staticmethod
    def index_of[T: ResourceType]() -> Int:
        """Returns the position of resource type ``T`` in this list.

        Parameters:
            T: The resource type to search for.

        Returns:
            The index of ``T`` if present; otherwise -1.
        """
        with Zone(function_name="Resources.index_of[T: ResourceType]()"):
            comptime for i in range(len(Self.ResourceTypes)):
                comptime if Self.ResourceTypes[i] == T:
                    return i
            return -1

    @staticmethod
    def contains[T: ResourceType]() -> Bool:
        """Returns whether resource type ``T`` is in this list.

        Parameters:
            T: The resource type to search for.

        Returns:
            True if ``T`` is present, False otherwise.
        """
        return Self.index_of[T]() != -1


@fieldwise_init
struct ResourceStorage(Copyable, Movable, Sized):
    """Manages resources."""

    comptime IdType = StringSlice[ImmStaticOrigin]
    """The type of the internal type IDs."""

    var _storage: Dict[Self.IdType, UnsafeBox]

    @always_inline
    def __init__(out self):
        """
        Constructs an empty resource container.
        """
        with Zone(function_name="ResourceStorage.__init__()"):
            self._storage = Dict[Self.IdType, UnsafeBox]()

    @always_inline("nodebug")
    def __len__(self) -> Int:
        """Gets the number of stored resources.

        Returns:
            The number of stored resources.
        """
        with Zone(function_name="ResourceStorage.__len__()"):
            return len(self._storage)

    def add[*Ts: ResourceType](mut self, var *resources: *Ts) raises:
        """Adds resources.

        Parameters:
            Ts: The types of the resources to add.

        Args:
            resources: The resources to add.

        Raises:
            Error: If some resource already exists.
        """

        with Zone(
            function_name=(
                "ResourceStorage.add[*Ts: ResourceType](var *resources: *Ts)"
            )
        ):
            var conflicting_ids = List[StringSlice[ImmStaticOrigin]](capacity=0)

            comptime for idx in range(len(Ts)):
                comptime id = reflect[Ts[idx]].name()
                if id in self._storage:
                    conflicting_ids.append(id)

            if conflicting_ids:
                raise Error("Duplicate resource: " + ", ".join(conflicting_ids))

            def take_resource[
                idx: Int
            ](var resource: Ts[idx]) capturing -> None:
                self._add(reflect[Ts[idx]].name(), resource^)

            resources^.consume_elements[take_resource]()

    @always_inline
    def _add(mut self, id: Self.IdType, var resource: Some[ResourceType]):
        """Adds a resource by ID.

        Args:
            id: The ID of the resource to add. It has to be not used already.
            resource: The resource to add.
        """
        with Zone(
            function_name=(
                "ResourceStorage._add(id: Self.IdType, var resource:"
                " Some[ResourceType])"
            )
        ):
            self._storage[id] = UnsafeBox(resource^)

    def set[
        *Ts: ResourceType, add_if_not_found: Bool = False
    ](mut self: ResourceStorage, var *resources: *Ts) raises:
        """Sets the values of resources.

        Parameters:
            Ts: The types of the resources to set.
            add_if_not_found: If true, adds resources that do not exist.

        Args:
            resources: The resources to set.

        Raises:
            Error: If one of the resources does not exist.
        """

        with Zone(
            function_name=(
                "ResourceStorage.set[*Ts: ResourceType, add_if_not_found:"
                " Bool](var *resources: *Ts)"
            )
        ):
            comptime if not add_if_not_found:
                var conflicting_ids = List[StringSlice[ImmStaticOrigin]]()

                comptime for idx in range(len(Ts)):
                    comptime id = reflect[Ts[idx]].name()
                    if id not in self._storage:
                        conflicting_ids.append(id)

                if len(conflicting_ids) > 0:
                    raise Error(
                        "Unknown resource: " + ", ".join(conflicting_ids)
                    )

            def take_resource[
                idx: Int
            ](var resource: Ts[idx]) capturing -> None:
                self._set[add_if_not_found=add_if_not_found](
                    reflect[Ts[idx]].name(),
                    resource^,
                )

            resources^.consume_elements[take_resource]()

    @always_inline
    def _set[
        add_if_not_found: Bool
    ](mut self, id: Self.IdType, var resource: Some[ResourceType]):
        """Sets the values of the resources

        Parameters:
            add_if_not_found: If true, adds resources that do not exist.

        Args:
            id: The ID of the resource to set. If add_if_not_found is false, the resource ID must be already known.
            resource: The resource to set.
        """

        with Zone(
            function_name=(
                "ResourceStorage._set[add_if_not_found: Bool](id: Self.IdType,"
                " var resource: Some[ResourceType])"
            )
        ):
            try:
                self._storage[id].unsafe_get[type_of(resource)]() = resource^
            except:
                comptime if add_if_not_found:
                    self._add(id, resource^)

    def remove[*Ts: ResourceType](mut self: ResourceStorage) raises:
        """Removes resources.

        Parameters:
            Ts: The types of the resources to remove.

        Raises:
            Error: If one of the resources does not exist.
        """

        with Zone(function_name="ResourceStorage.remove[*Ts: ResourceType]()"):
            comptime for i in range(len(Ts)):
                self._remove[Ts[i]](reflect[Ts[i]].name())

    @always_inline
    def _remove[T: ResourceType](mut self, id: Self.IdType) raises:
        """Removes resources.

        Parameters:
            T: The type of the resource to remove.

        Raises:
            Error: If the resource does not exist.
        """
        with Zone(
            function_name=(
                "ResourceStorage._remove[T: ResourceType](id: Self.IdType)"
            )
        ):
            try:
                _ = self._storage.pop(id)
            except DictKeyError:
                raise Error(t"The resource `{id}` does not exist.")

    @always_inline
    def get[
        T: ResourceType
    ](ref self) raises -> ref[UnsafeAnyOrigin[mut=origin_of(self).mut]] T:
        """Gets a resource.

        Parameters:
            T: The type of the resource to get.

        Raises:
            Error: If the resource does not exist.

        Returns:
            A reference with ``UnsafeAnyOrigin``, preserving the mutability
            of the storage access.

        Note:
            Keep ``UnsafeAnyOrigin`` until Mojo's origin system can model
            the ownership relation between the resource container and its
            separately allocated resource values. Tying this reference to
            the storage origin is not a suitable interim replacement.
        """
        with Zone(function_name="ResourceStorage.get[T: ResourceType]()"):
            try:
                return Pointer(
                    to=self._storage[reflect[T].name()].unsafe_get[T]()
                ).as_unsafe_any_origin()[]
            except DictKeyError:
                raise Error(
                    t"The resource `{reflect[T].name()}` does not exist."
                )

    @always_inline
    def has[T: ResourceType](mut self) -> Bool:
        """Checks if the resource is present.

        Parameters:
            T: The type of the resource to check.

        Returns:
            True if the resource is present, otherwise False.
        """
        with Zone(function_name="ResourceStorage.has[T: ResourceType]()"):
            return reflect[T].name() in self._storage
