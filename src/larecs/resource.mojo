"""Resource types and host-side resource storage.

Provides `Resources`, a compile-time list of resource types, and
`ResourceStorage`, which holds one instance of each resource by type.
"""

from std.collections.dict import Dict, DictKeyError
from std.collections import Set
from .resource_representation import _plain_device_value
from .resource_adapter import (
    DevicePassableResource,
    ResourceDeviceCache,
    _TransferFrame,
)
from std.reflection import reflect
from std.sys import size_of
from std.os import abort
from std.memory import (
    is_trivially_movable,
    is_trivially_copyable,
    is_trivially_deletable,
)

from max.gpu.host import DeviceContext, DevicePointer

from tracy import Zone

from .unsafe_box import UnsafeBox

comptime ResourceType = Copyable & Deinitable
"""The trait that resources must conform to."""

comptime DeviceResourceType = TrivialRegisterPassable
"""Legacy alias for trivially register-passable resource values.

Ordinary device eligibility is checked recursively by
[.constrain_device_safe_resources]. Owning sources instead opt into
[..resource_adapter.DevicePassableResource] with a read-only kernel view.
"""


def constrain_device_safe_resources[*Ts: ResourceType]() -> Bool:
    """Checks whether all resource types are safe for device raw-byte transfer.

    Parameters:
        Ts: The resource types to check.

    Returns:
        True when every type has a supported pointer-free trivial representation.
    """
    with Zone(
        function_name=(
            "resource.constrain_device_safe_resources[*Ts: ResourceType]()"
        )
    ):
        comptime for i in range(len(Ts)):
            comptime if not _plain_device_value[Ts[i]]():
                return False
        return True


@fieldwise_init
struct _ResourceTypes[*Types: ResourceType]:
    """Internal type-only resource access group."""

    pass


@fieldwise_init
struct Resources[
    *ResourceTypes: ResourceType,
    _readonly: _ResourceTypes = _ResourceTypes[](),
    _writeonly: _ResourceTypes = _ResourceTypes[](),
](Sized):
    """Ordered source declarations with read, write, or read_write access.

    Parameters:
        ResourceTypes: Resource source types; constructor defaults to read_write.
        _readonly: Internal source types restricted to read access.
        _writeonly: Internal source types restricted to write access.
    """

    comptime _mode[T: ResourceType] = 1 if Self._readonly.Types.contains[
        T
    ]() else (2 if Self._writeonly.Types.contains[T]() else 3)

    def read[
        *Ts: ResourceType
    ](self) -> Resources[
        *TypeList._concat[Self.ResourceTypes.values, Ts.values](),
        _readonly=_ResourceTypes[
            *TypeList._concat[Self._readonly.Types.values, Ts.values]()
        ](),
        _writeonly=Self._writeonly,
    ]:
        """Appends read-only sources.

        Parameters:
            Ts: Types exposed as immutable sources or portable views.

        Returns:
            Extended access declarations.
        """
        return {}

    def write[
        *Ts: ResourceType
    ](self) -> Resources[
        *TypeList._concat[Self.ResourceTypes.values, Ts.values](),
        _readonly=Self._readonly,
        _writeonly=_ResourceTypes[
            *TypeList._concat[Self._writeonly.Types.values, Ts.values]()
        ](),
    ]:
        """Appends host set-only sources; device write access is unsupported.

        Parameters:
            Ts: Types available through set only.

        Returns:
            Extended access declarations.
        """
        return {}

    def read_write[
        *Ts: ResourceType
    ](self) -> Resources[
        *TypeList._concat[Self.ResourceTypes.values, Ts.values](),
        _readonly=Self._readonly,
        _writeonly=Self._writeonly,
    ]:
        """Appends mutable sources.

        Parameters:
            Ts: Types exposed as mutable source references.

        Returns:
            Extended access declarations.
        """
        return {}

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
    var _bindings: Set[Self.IdType]
    var _leases: Set[Self.IdType]
    var _device_cache: Dict[Self.IdType, ResourceDeviceCache]
    var _poisoned: Bool

    def __init__(out self, *, copy: Self):
        """Copies host sources and type metadata, resetting device allocations.

        Args:
            copy: Idle, healthy resource storage.
        """
        if copy._poisoned or len(copy._leases) != 0:
            abort("Cannot copy leased or unusable resources")
        self._storage = copy._storage.copy()
        self._bindings = copy._bindings.copy()
        self._leases = Set[Self.IdType]()
        self._device_cache = Dict[Self.IdType, ResourceDeviceCache]()
        self._poisoned = False

    def __init__(out self, *, deinit move: Self):
        """Moves idle sources and their context-local caches together.

        Args:
            move: Idle storage to transfer; moving a live lease aborts.
        """
        if len(move._leases) != 0:
            abort("Cannot move leased resources")
        self._storage = move._storage^
        self._bindings = move._bindings^
        self._leases = move._leases^
        self._device_cache = move._device_cache^
        self._poisoned = move._poisoned

    def __deinit__(deinit self):
        """Rejects destruction or table replacement while sources are leased."""
        if len(self._leases) != 0:
            abort("Cannot destroy leased resources")

    def _check(self, id: Self.IdType) raises:
        """Rejects resource access during a live binding or after queue failure.

        Args:
            id: Requested source identity.

        Raises:
            Error: If the source is leased or the world cannot safely run again.
        """
        self._check_healthy()
        if id in self._leases:
            raise Error(t"Resource `{id}` is bound by an active invocation")

    def _check_healthy(self) raises:
        """Rejects reuse when device completion could not be confirmed.

        Raises:
            Error: If a prior device failure left completion unknown.
        """
        if self._poisoned:
            raise Error("World is unusable after unconfirmed device completion")

    @always_inline
    def __init__(out self):
        """
        Constructs an empty resource container.
        """
        with Zone(function_name="ResourceStorage.__init__()"):
            self._storage = Dict[Self.IdType, UnsafeBox]()
            self._bindings = Set[Self.IdType]()
            self._leases = Set[Self.IdType]()
            self._device_cache = Dict[Self.IdType, ResourceDeviceCache]()
            self._poisoned = False

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
            Error: If a resource already exists, is leased, or storage is unusable.
        """

        with Zone(
            function_name=(
                "ResourceStorage.add[*Ts: ResourceType](var *resources: *Ts)"
            )
        ):
            var conflicting_ids = List[StringSlice[ImmStaticOrigin]](capacity=0)

            comptime for idx in range(len(Ts)):
                comptime id = reflect[Ts[idx]].name()
                self._check(id)
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
            comptime T = type_of(resource)
            comptime if conforms_to(T, DevicePassableResource):
                comptime assert conforms_to(T, DevicePassableResource)
                _validate_adapter_type[T]()
                self._bindings.add(id)
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
            Error: If a resource is missing, leased, or storage is unusable.
        """

        with Zone(
            function_name=(
                "ResourceStorage.set[*Ts: ResourceType, add_if_not_found:"
                " Bool](var *resources: *Ts)"
            )
        ):
            comptime for i in range(len(Ts)):
                self._check(reflect[Ts[i]].name())
            comptime if not add_if_not_found:
                var conflicting_ids = List[StringSlice[ImmStaticOrigin]]()

                comptime for idx in range(len(Ts)):
                    comptime id = reflect[Ts[idx]].name()
                    self._check(id)
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
            Error: If a resource is missing, leased, or storage is unusable.
        """

        with Zone(function_name="ResourceStorage.remove[*Ts: ResourceType]()"):
            comptime for i in range(len(Ts)):
                self._check(reflect[Ts[i]].name())
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
                self._bindings.discard(id)
                if id in self._device_cache:
                    _ = self._device_cache.pop(id)
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
            Error: If the resource is missing, leased, or storage is unusable.

        Returns:
            A reference with ``UnsafeAnyOrigin``, preserving the mutability
            of the storage access.

        Note:
            Keep ``UnsafeAnyOrigin`` until Mojo's origin system can model
            the ownership relation between the resource container and its
            separately allocated resource values. Tying this reference to
            the storage origin is not a suitable interim replacement.
        """
        self._check(reflect[T].name())
        return self._get_bound[T]()

    def _get_bound[
        T: ResourceType
    ](ref self) raises -> ref[UnsafeAnyOrigin[mut=origin_of(self).mut]] T:
        """Looks up a source for an already validated internal invocation.

        Parameters:
            T: The source type.

        Raises:
            Error: If the source is missing.

        Returns:
            The authoritative source reference, retaining storage mutability.
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


def _view_device_value[T: AnyType]() -> Bool:
    """Checks trivial descriptors, permitting immutable adapter-managed pointers.

    Parameters:
        T: Descriptor or nested field type.

    Returns:
        Whether the representation can be used as a read-only kernel descriptor.
        Pointer addresses and sample validity remain the adapter's contract.
    """
    comptime if not conforms_to(T, Copyable):
        return False
    else:
        comptime assert conforms_to(T, Copyable)
        comptime if not (
            is_trivially_copyable[T]()
            and is_trivially_deletable[T]()
            and is_trivially_movable[T]()
        ):
            return False
        elif not reflect[T].is_struct():
            return False
        elif reflect[T].name().startswith("std.memory.pointer.Pointer[False,"):
            return True
        elif T == Bool or reflect[T].name().startswith("SIMD["):
            return True
        else:
            comptime fields = reflect[T].field_types()
            comptime for i in range(len(fields)):
                comptime if not _view_device_value[fields[i]]():
                    return False
            return True


def _validate_adapter_type[T: DevicePassableResource]():
    """Checks source, adapter, and read-only view agreement at registration.

    Parameters:
        T: Opt-in source type.

    Constraints:
        Adapter types must match the source and its immutable trivial descriptor.
    """
    comptime assert (
        T.Adapter.Source == T
    ), "Adapter.Source must equal the resource type"
    comptime assert (
        T.Adapter.View == T.KernelView
    ), "Adapter.View must equal KernelView"
    comptime assert _view_device_value[
        T.KernelView
    ](), "KernelView requires trivial metadata and immutable pointers"


def _validate_resource_spec[spec: Resources, device: Bool]():
    """Checks source identity and access before either execution backend.

    Parameters:
        spec: Invocation declarations.
        device: Whether device execution was requested, including fallback hosts.

    Constraints:
        Sources must be unique. Adapted resources require read access.
        Device write-only resources are unsupported.
    """
    comptime for i in range(len(spec)):
        comptime T = spec.ResourceTypes[i]
        comptime for j in range(i):
            comptime assert (
                T != spec.ResourceTypes[j]
            ), "Duplicate resource source declaration"
        comptime if conforms_to(T, DevicePassableResource):
            comptime assert conforms_to(T, DevicePassableResource)
            _validate_adapter_type[T]()
            comptime assert (
                spec._mode[T] == 1
            ), "DevicePassableResource requires read access on both targets"
        elif device:
            comptime assert (
                spec._mode[T] != 2
            ), "Device write-only resources are unsupported"
            comptime assert _plain_device_value[T](), (
                "Device resources require pointer-free trivial plain values or"
                " DevicePassableResource"
            )


struct _ResourceInvocation[spec: Resources, origin: MutOrigin](Movable):
    """Retains source leases and host descriptors for one synchronous run.

    Parameters:
        spec: Ordered source access declarations.
        origin: Borrow of the source storage retained through invocation release.
    """

    var _storage: Pointer[ResourceStorage, Self.origin]
    var _views: Array[Optional[UnsafeBox], len(Self.spec)]
    var pointers: Array[Pointer[UInt8, MutUntrackedOrigin], len(Self.spec)]
    var _leased: Bool

    def __init__(out self, ref[Self.origin] storage: ResourceStorage) raises:
        """Validates every source before acquiring any invocation leases.

        Args:
            storage: Authoritative source storage retained by the caller.

        Raises:
            Error: If a source is missing, leased, unusable, or invalid.
        """
        self._storage = Pointer(to=storage)
        self._views = {fill = None}
        self.pointers = {uninitialized = True}
        self._leased = False
        storage._check_healthy()
        comptime for i in range(len(Self.spec)):
            comptime T = Self.spec.ResourceTypes[i]
            storage._check(reflect[T].name())
            ref source = storage._get_bound[T]()
            comptime if conforms_to(T, DevicePassableResource):
                comptime assert conforms_to(T, DevicePassableResource)
                if reflect[T].name() not in storage._bindings:
                    raise Error("Resource adapter was not registered")
                T.Adapter.validate(
                    Pointer(to=source).unsafe_bitcast[T.Adapter.Source]()[]
                )
        comptime for i in range(len(Self.spec)):
            storage._leases.add(reflect[Self.spec.ResourceTypes[i]].name())
        self._leased = True

    def __deinit__(deinit self):
        """Releases invocation leases after the synchronous execution boundary.
        """
        self.release()

    def release(mut self):
        """Ends the source lease explicitly after the last kernel and queue use.
        """
        if self._leased:
            self._leased = False
            comptime for i in range(len(Self.spec)):
                self._storage[]._leases.discard(
                    reflect[Self.spec.ResourceTypes[i]].name()
                )

    def bind_host(mut self) raises:
        """Constructs host descriptors without queueing device work.

        Raises:
            Error: If host descriptor construction fails.
        """
        comptime for i in range(len(Self.spec)):
            comptime T = Self.spec.ResourceTypes[i]
            ref source = self._storage[]._get_bound[T]()
            comptime if conforms_to(T, DevicePassableResource):
                comptime assert conforms_to(T, DevicePassableResource)
                var view = T.Adapter.bind_host(
                    Pointer(to=source).unsafe_bitcast[T.Adapter.Source]()[]
                )
                self._views[i] = UnsafeBox(view)
                self.pointers[i] = Pointer[UInt8, MutUntrackedOrigin](
                    unsafe_from_address=Int(
                        Pointer(
                            to=self._views[i]
                            .unsafe_value()
                            .unsafe_get[T.KernelView]()
                        )
                    )
                )
            else:
                self.pointers[i] = Pointer[UInt8, MutUntrackedOrigin](
                    unsafe_from_address=Int(Pointer(to=source))
                )

    def validate_device(self, context: DeviceContext) raises:
        """Checks every existing cache's context before any queue work.

        Args:
            context: The world's execution queue.

        Raises:
            Error: If an existing cache belongs to a different context.
        """
        comptime for i in range(len(Self.spec)):
            comptime id = reflect[Self.spec.ResourceTypes[i]].name()
            if id in self._storage[]._device_cache:
                if (
                    self._storage[]._device_cache[id].context._handle
                    != context._handle
                ):
                    raise Error(
                        "Resource cache belongs to a different device context"
                    )

    def bind_device(
        mut self, context: DeviceContext, mut frame: _TransferFrame
    ) raises -> Array[
        DevicePointer[mut=True, DType.uint8, MutUntrackedOrigin], len(Self.spec)
    ]:
        """Uploads current resources using source-keyed context-local caches.

        Args:
            context: The world's device queue.
            frame: Invocation-owned staging and publication state.

        Raises:
            Error: If cache ownership, allocation, or preparation fails.

        Returns:
            Device pointers indexed by source declaration order.
        """
        var result = Array[
            DevicePointer[mut=True, DType.uint8, MutUntrackedOrigin],
            len(Self.spec),
        ](uninitialized=True)
        comptime for i in range(len(Self.spec)):
            comptime T = Self.spec.ResourceTypes[i]
            comptime id = reflect[T].name()
            ref storage = self._storage[]
            if id not in storage._device_cache:
                storage._device_cache[id] = ResourceDeviceCache(context)
            ref source = storage._get_bound[T]()
            ref cache = storage._device_cache[id]
            if cache.context._handle != context._handle:
                raise Error(
                    "Resource cache belongs to a different device context"
                )
            comptime if conforms_to(T, DevicePassableResource):
                comptime assert conforms_to(T, DevicePassableResource)
                var view = T.Adapter.prepare_device(
                    Pointer(to=source).unsafe_bitcast[T.Adapter.Source]()[],
                    cache,
                )
                _ = cache._descriptor(view)
                result[i] = rebind[
                    DevicePointer[mut=True, DType.uint8, MutUntrackedOrigin]
                ](cache._buffers[-1].device_ptr())
            else:
                var descriptor = cache._ensure(-1, max(1, size_of[T]()))
                if size_of[T]() > 0:
                    frame.upload(
                        descriptor.create_sub_buffer[DType.uint8](
                            0, size_of[T]()
                        ),
                        Pointer(to=source)
                        .unsafe_bitcast[UInt8]()
                        .unsafe_mut_cast[False](),
                    )
                result[i] = rebind[
                    DevicePointer[mut=True, DType.uint8, MutUntrackedOrigin]
                ](cache._buffers[-1].device_ptr())
        # DevicePointer borrows the cached DeviceBuffer object itself. Never
        # form it from the temporary native handle returned by _ensure.
        return result^

    def download(mut self, mut frame: _TransferFrame) raises:
        """Stages mutable plain resources without publishing partial results.

        Args:
            frame: Invocation's staged output owner.

        Raises:
            Error: If enqueueing a resource download fails.
        """
        comptime for i in range(len(Self.spec)):
            comptime T = Self.spec.ResourceTypes[i]
            comptime if Self.spec._mode[T] == 3 and size_of[T]() > 0:
                ref source = self._storage[]._get_bound[T]()
                frame.download(
                    self._storage[]
                    ._device_cache[reflect[T].name()]
                    ._buffers[-1]
                    .create_sub_buffer[DType.uint8](0, size_of[T]()),
                    Pointer[UInt8, MutUntrackedOrigin](
                        unsafe_from_address=Int(Pointer(to=source))
                    ),
                )


def _synchronize_queue(context: DeviceContext) raises:
    """Confirms completion on the invocation's device queue.

    Args:
        context: Queue to drain.

    Raises:
        Error: If completion cannot be confirmed.
    """
    context.synchronize()


def _drain_failed_device[
    Sync: def(DeviceContext) raises thin -> None = _synchronize_queue
](
    mut resources: ResourceStorage,
    context: DeviceContext,
    var error: Error,
    mut world_unusable: Bool,
) raises:
    """Drains failed work, poisoning execution if completion remains unknown.

    Parameters:
        Sync: Queue completion operation; substitutable for deterministic tests.

    Args:
        resources: Source storage disabled after unconfirmed completion.
        context: Queue used by the failed invocation.
        error: Original failure, preserved when draining succeeds.
        world_unusable: World-level flag retained across resource-table replacement.

    Raises:
        Error: Original failure or combined operation/completion failures.
    """
    try:
        Sync(context)
    except drain_error:
        world_unusable = True
        resources._poisoned = True
        raise Error(
            t"Device failure: {String(error)}; completion unconfirmed:"
            t" {String(drain_error)}"
        )
    raise error^
