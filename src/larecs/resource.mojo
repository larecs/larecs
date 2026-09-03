from std.collections.dict import Dict, DictKeyError
from std.reflection import reflect
from std.sys import size_of

from max.gpu.host import DeviceBuffer, DeviceContext, DevicePointer

from tracy import Zone

from .unsafe_box import UnsafeBox

comptime ResourceType = Copyable & Deinitable
"""The trait that resources must conform to."""


@fieldwise_init
struct Resources[*ResourceTypes: ResourceType](Sized):
    def __len__(self) -> Int:
        """Returns the number of component types included by the filter."""
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
        return Self.index_of[T]() != -1


struct DeviceResourceStorage[resources: Resources](Copyable):
    """Owns one byte-addressed device buffer per resource type required by
    a kernel.

    Mirrors [.DeviceStorage], but keyed by position in ``resources`` instead
    of by a [.ComponentManager]-assigned id: each kernel invocation uploads
    exactly the (small, fixed) set of resources it declared as required,
    rather than mirroring the whole resource table to the device.
    """

    comptime Buffers = Array[
        Optional[DeviceBuffer[DType.uint8]], len(Self.resources)
    ]
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
        """
        with Zone(
            function_name=(
                "DeviceResourceStorage.upload[T: ResourceType](ref value: T)"
            )
        ):
            comptime id = Self.resources.index_of[T]()
            comptime assert id != -1, "T is not part of `resources`"

            self._buffers[id] = self._device_context.create_buffer_sync[
                DType.uint8
            ](size_of[T]())
            self._buffers[id].unsafe_value().enqueue_copy_from(
                Pointer(to=value).unsafe_bitcast[UInt8]()
            )

    def get_device_ptr[
        T: ResourceType
    ](self) raises -> DevicePointer[mut=True, DType.uint8, MutUntrackedOrigin]:
        """Returns the device pointer backing resource ``T``.

        Parameters:
            T: The type of the resource to look up. Must have been
                [.upload]ed already.

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
        with Zone(function_name="DeviceResourceStorage.synchronize()"):
            self._device_context.synchronize()


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

        Returns:
            A reference to the resource.
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
