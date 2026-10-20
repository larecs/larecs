"""Resource types and host-side resource storage.

Provides `Resources`, a compile-time list of resource types, and
`ResourceStorage`, which holds one instance of each resource by type.
"""

from std.collections.dict import Dict, DictKeyError
from std.collections import Set
from .resource_representation import _plain_device_value
from .resource_adapter import (
    DevicePassableResource,
    ResourceAccess,
    ResourceDeviceCache,
    _TransferFrame,
    _TransferStats,
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

from ._zones import FineZone

from .unsafe_box import UnsafeBox

comptime ResourceType = Copyable & Deinitable
"""The trait that resources must conform to."""

comptime DeviceResourceType = TrivialRegisterPassable
"""Legacy alias for trivially register-passable resource values.

Ordinary device eligibility is checked recursively by
[.constrain_device_safe_resources]. Owning sources instead opt into
[..resource_adapter.DevicePassableResource] with access-selected kernel views.
"""


def constrain_device_safe_resources[*Ts: ResourceType]() -> Bool:
    """Checks whether all resource types are safe for device raw-byte transfer.

    Parameters:
        Ts: The resource types to check.

    Returns:
        True when every type has a supported pointer-free trivial representation.
    """
    with FineZone(
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

    comptime access[T: ResourceType] = ResourceAccess(Self._mode[T])
    """Declared access of a source; undeclared types report `READ_WRITE`.

    Parameters:
        T: The source type.
    """

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
        """Appends write-only sources.

        Ordinary sources offer host `set` only; device write access is
        unsupported for them. Adapted sources whose adapter supports mutation
        expose `View[True]` over fresh, adapter-initialized output.

        Parameters:
            Ts: Ordinary types available through set, or mutable adapted sources.

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
        """Appends mutable sources preserving existing contents.

        Parameters:
            Ts: Ordinary types exposed as mutable source references, or adapted
                sources exposing `View[True]` over their current contents.

        Returns:
            Extended access declarations.
        """
        return {}

    def __len__(self) -> Int:
        """Returns the number of component types included by the filter.

        Returns:
            The number of resource types.
        """
        with FineZone(function_name="Resources.__len__()"):
            return len(self.ResourceTypes)

    @staticmethod
    def index_of[T: ResourceType]() -> Int:
        """Returns the position of resource type ``T`` in this list.

        Parameters:
            T: The resource type to search for.

        Returns:
            The index of ``T`` if present; otherwise -1.
        """
        with FineZone(function_name="Resources.index_of[T: ResourceType]()"):
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
struct _ResourceEntry(Copyable, Movable):
    """One stored source and the revision of its last host mutation."""

    var box: UnsafeBox
    var revision: UInt64


@fieldwise_init
struct ResourceStorage(Copyable, Movable, Sized):
    """Manages resources.

    Every resource carries a revision that conservatively advances on each
    Larecs access that may mutate it (decision 0021). Worlds that opt into
    device copy reuse skip uploading resources whose device copy was
    transferred at the current revision. Mutations through references
    obtained before a later Larecs call, or through raw pointers, are not
    detected: re-obtain references after a run, or call
    `invalidate_device[T]()`.
    """

    comptime IdType = StringSlice[ImmStaticOrigin]
    """The type of the internal type IDs."""

    var _storage: Dict[Self.IdType, _ResourceEntry]
    var _bindings: Set[Self.IdType]
    var _leases: Set[Self.IdType]
    var _device_cache: Dict[Self.IdType, ResourceDeviceCache]
    var _poisoned: Bool
    var _clock: UInt64
    """Last issued revision; values are never reused by this storage."""
    var _device_revisions: Dict[Self.IdType, UInt64]
    """Revision at which each device copy matched the host source."""
    var _reuse_device: Bool
    """Whether device runs may skip uploads of unchanged resources."""

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
        self._clock = copy._clock
        self._device_revisions = Dict[Self.IdType, UInt64]()
        self._reuse_device = copy._reuse_device

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
        self._clock = move._clock
        self._device_revisions = move._device_revisions^
        self._reuse_device = move._reuse_device

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
        with FineZone(function_name="ResourceStorage.__init__()"):
            self._storage = Dict[Self.IdType, _ResourceEntry]()
            self._bindings = Set[Self.IdType]()
            self._leases = Set[Self.IdType]()
            self._device_cache = Dict[Self.IdType, ResourceDeviceCache]()
            self._poisoned = False
            self._clock = 0
            self._device_revisions = Dict[Self.IdType, UInt64]()
            self._reuse_device = False

    @always_inline("nodebug")
    def __len__(self) -> Int:
        """Gets the number of stored resources.

        Returns:
            The number of stored resources.
        """
        with FineZone(function_name="ResourceStorage.__len__()"):
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

        with FineZone(
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
        with FineZone(
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
            self._storage[id] = _ResourceEntry(
                UnsafeBox(resource^), self._next_revision()
            )

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

        with FineZone(
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

        with FineZone(
            function_name=(
                "ResourceStorage._set[add_if_not_found: Bool](id: Self.IdType,"
                " var resource: Some[ResourceType])"
            )
        ):
            try:
                ref entry = self._storage[id]
                entry.box.unsafe_get[type_of(resource)]() = resource^
                entry.revision = self._next_revision()
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

        with FineZone(
            function_name="ResourceStorage.remove[*Ts: ResourceType]()"
        ):
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
        with FineZone(
            function_name=(
                "ResourceStorage._remove[T: ResourceType](id: Self.IdType)"
            )
        ):
            try:
                _ = self._storage.pop(id)
                self._bindings.discard(id)
                if id in self._device_cache:
                    _ = self._device_cache.pop(id)
                self._drop_device_record(id)
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

            Through mutable storage, every call counts as a mutation and
            invalidates the resource's device copy, even if the reference is
            only read. Use ``read`` for reads between device runs. Writes
            through a reference kept across a later run are not detected;
            re-obtain it or call ``invalidate_device[T]()``.
        """
        comptime id = reflect[T].name()
        self._check(id)
        comptime if origin_of(self).mut:
            _ = Pointer(to=self).unsafe_mut_cast[True]()[]._touch(id)
        return self._get_bound[T]()

    @always_inline
    def read[T: ResourceType](self) raises -> ref[UnsafeAnyOrigin[mut=False]] T:
        """Gets an immutable resource reference without counting a mutation.

        Unlike ``get`` through mutable storage, this keeps an unchanged
        resource's device copy reusable in worlds that opted into
        ``reuse_device_copies``.

        Parameters:
            T: The type of the resource to read.

        Raises:
            Error: If the resource is missing, leased, or storage is unusable.

        Returns:
            An immutable reference with ``UnsafeAnyOrigin``; see ``get``.
        """
        self._check(reflect[T].name())
        return self._get_bound[T]()

    def invalidate_device[T: ResourceType](mut self):
        """Marks one resource's device copy stale.

        Call this after mutating a resource through a reference obtained
        before a later Larecs call, or through a raw pointer, in a world that
        reuses device copies. The next device run uploads the resource again.

        Parameters:
            T: The resource type whose device copy is invalidated.
        """
        self._drop_device_record(reflect[T].name())

    def _invalidate_device_copies(mut self):
        """Marks every resource's device copy stale."""
        self._device_revisions.clear()

    def _set_reuse_device(mut self, enabled: Bool):
        """Enables or disables skipping unchanged resource uploads.

        Disabling discards every device copy record.

        Args:
            enabled: Whether device runs may reuse unchanged device copies.
        """
        self._reuse_device = enabled
        if not enabled:
            self._invalidate_device_copies()

    @always_inline
    def _next_revision(mut self) -> UInt64:
        """Issues a fresh revision.

        Returns:
            A value greater than every revision issued before.
        """
        self._clock += 1
        return self._clock

    @always_inline
    def _touch(mut self, id: Self.IdType) -> UInt64:
        """Advances a resource's revision after a possible mutation.

        Args:
            id: Source identity; missing sources are ignored.

        Returns:
            The new revision, or 0 if the source is missing.
        """
        var revision = self._next_revision()
        try:
            self._storage[id].revision = revision
        except DictKeyError:
            return 0
        return revision

    def _revision(self, id: Self.IdType) -> UInt64:
        """Returns a resource's current revision.

        Args:
            id: Source identity.

        Returns:
            The revision of the last possible mutation, or 0 if missing.
        """
        try:
            return self._storage[id].revision
        except DictKeyError:
            return 0

    def _device_copy_current(self, id: Self.IdType) -> Bool:
        """Checks whether a reusable device copy matches the host source.

        Args:
            id: Source identity.

        Returns:
            Whether reuse is enabled, a cache exists, and its record matches.
        """
        if not self._reuse_device or id not in self._device_cache:
            return False
        try:
            return self._device_revisions[id] == self._storage[id].revision
        except DictKeyError:
            return False

    @always_inline
    def _drop_device_record(mut self, id: Self.IdType):
        """Marks one device copy unknown.

        Args:
            id: Source identity.
        """
        if id in self._device_revisions:
            try:
                _ = self._device_revisions.pop(id)
            except DictKeyError:
                pass

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
        with FineZone(function_name="ResourceStorage.get[T: ResourceType]()"):
            try:
                return Pointer(
                    to=self._storage[reflect[T].name()].box.unsafe_get[T]()
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
        with FineZone(function_name="ResourceStorage.has[T: ResourceType]()"):
            return reflect[T].name() in self._storage


def _view_device_value[T: AnyType, allow_mutable: Bool = False]() -> Bool:
    """Checks trivial descriptors, permitting adapter-managed pointers.

    Parameters:
        T: Descriptor or nested field type.
        allow_mutable: Whether mutable pointers are permitted (mutable views).

    Returns:
        Whether the representation can be used as a kernel descriptor.
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
        elif reflect[T].name().startswith("std.memory.pointer.Pointer[True,"):
            return allow_mutable
        elif T == Bool or reflect[T].name().startswith("SIMD["):
            return True
        else:
            comptime fields = reflect[T].field_types()
            comptime for i in range(len(fields)):
                comptime if not _view_device_value[fields[i], allow_mutable]():
                    return False
            return True


def _validate_adapter_type[T: DevicePassableResource]():
    """Checks source, adapter, and view agreement at registration.

    Parameters:
        T: Opt-in source type.

    Constraints:
        Adapter types must match the source. The read view is an immutable
        trivial descriptor; mutable views may also hold mutable pointers.
        Concurrent mutation requires mutation support.
    """
    comptime assert (
        T.Adapter.Source == T
    ), "Adapter.Source must equal the resource type"
    comptime assert (
        T.View[False] == T.Adapter.View[False]
        and T.View[True] == T.Adapter.View[True]
    ), "View must forward to Adapter.View"
    comptime assert (
        T.KernelView == T.View[False]
    ), "KernelView must equal View[False]"
    comptime assert _view_device_value[
        T.View[False]
    ](), "KernelView requires trivial metadata and immutable pointers"
    comptime assert (
        T.Adapter.supports_mutation
        or not T.Adapter.supports_concurrent_mutation
    ), "supports_concurrent_mutation requires supports_mutation"
    comptime if T.Adapter.supports_mutation:
        comptime assert _view_device_value[
            T.View[True], True
        ](), "View[True] requires trivial metadata and adapter-managed pointers"


def _validate_resource_spec[
    spec: Resources, device: Bool, concurrent: Bool = False
]():
    """Checks source identity and access before any execution backend.

    Parameters:
        spec: Invocation declarations.
        device: Whether device execution was requested, including fallback hosts.
        concurrent: Whether threaded host execution was requested.

    Constraints:
        Sources must be unique. Mutable adapted access requires
        `supports_mutation`, plus `supports_concurrent_mutation` for device or
        threaded execution. Device write-only ordinary resources are unsupported.
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
            comptime if spec._mode[T] != 1:
                comptime assert T.Adapter.supports_mutation, (
                    "DevicePassableResource mutable access requires"
                    " Adapter.supports_mutation"
                )
                comptime assert (
                    not (device or concurrent)
                    or T.Adapter.supports_concurrent_mutation
                ), (
                    "Device or threaded mutable adapted access requires"
                    " Adapter.supports_concurrent_mutation"
                )
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

    Lifecycle: the constructor validates every declaration and source before
    leasing; host binding or device preparation creates invocation-owned views;
    kernels share them across all ranges and chunks; device outputs are staged
    and published after completion; `finalize` then completes mutable adapted
    results once; `release` ends the leases.

    Parameters:
        spec: Ordered source access declarations.
        origin: Borrow of the source storage retained through invocation release.
    """

    comptime _mutable_adapted[T: ResourceType] = conforms_to(
        T, DevicePassableResource
    ) and Self.spec._mode[T] != 1
    """Whether `T` is an adapted source bound through its mutable view."""

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

        Advances the revision of every resource declared writable, since the
        host kernel may mutate it. Mutable adapted sources prepare their host
        backing storage here, once for all ranges and chunks.

        Raises:
            Error: If host descriptor construction or preparation fails.
        """
        comptime for i in range(len(Self.spec)):
            comptime T = Self.spec.ResourceTypes[i]
            comptime if Self.spec._mode[T] != 1:
                _ = self._storage[]._touch(reflect[T].name())
            ref source = self._storage[]._get_bound[T]()
            comptime if conforms_to(T, DevicePassableResource):
                comptime assert conforms_to(T, DevicePassableResource)
                comptime if Self.spec._mode[T] == 1:
                    self._views[i] = UnsafeBox(
                        T.Adapter.bind_host(
                            Pointer(to=source).unsafe_bitcast[
                                T.Adapter.Source
                            ]()[]
                        )
                    )
                    self.pointers[i] = self._view_pointer[T.View[False]](i)
                else:
                    self._views[i] = UnsafeBox(
                        T.Adapter.bind_host_mutable[Self.spec.access[T]](
                            Pointer(to=source).unsafe_bitcast[
                                T.Adapter.Source
                            ]()[]
                        )
                    )
                    self.pointers[i] = self._view_pointer[T.View[True]](i)
            else:
                self.pointers[i] = Pointer[UInt8, MutUntrackedOrigin](
                    unsafe_from_address=Int(Pointer(to=source))
                )

    def _view_pointer[
        V: TrivialRegisterPassable
    ](self, index: Int) -> Pointer[UInt8, MutUntrackedOrigin]:
        """Addresses one retained host descriptor.

        Parameters:
            V: Stored descriptor type.

        Args:
            index: Declaration position whose descriptor is boxed.

        Returns:
            Untracked byte pointer valid until the invocation is destroyed.
        """
        return Pointer[UInt8, MutUntrackedOrigin](
            unsafe_from_address=Int(
                Pointer(to=self._views[index].unsafe_value().unsafe_get[V]())
            )
        )

    def complete_without_launch(mut self) raises:
        """Prepares and finalizes mutable adapted sources for an empty device run.

        No rows match, so no device work is queued: `WRITE` output is
        initialized on the host and every mutable adapted source is finalized,
        exactly as for a host run without matches. Other sources are untouched.

        Raises:
            Error: If preparation or finalization fails.
        """
        comptime for i in range(len(Self.spec)):
            comptime T = Self.spec.ResourceTypes[i]
            comptime if Self._mutable_adapted[T]:
                comptime assert conforms_to(T, DevicePassableResource)
                comptime id = reflect[T].name()
                _ = self._storage[]._touch(id)
                self._storage[]._drop_device_record(id)
                ref source = self._storage[]._get_bound[T]()
                _ = T.Adapter.bind_host_mutable[Self.spec.access[T]](
                    Pointer(to=source).unsafe_bitcast[T.Adapter.Source]()[]
                )
        self.finalize()

    def finalize(mut self) raises:
        """Completes mutable adapted results after execution and publication.

        Runs once per invocation, after every kernel range or worker finished
        and staged device outputs were published.

        Raises:
            Error: If an adapter reports a result failure; outputs stay published.
        """
        comptime for i in range(len(Self.spec)):
            comptime T = Self.spec.ResourceTypes[i]
            comptime if Self._mutable_adapted[T]:
                comptime assert conforms_to(T, DevicePassableResource)
                ref source = self._storage[]._get_bound[T]()
                T.Adapter.finalize[Self.spec.access[T]](
                    Pointer(to=source).unsafe_bitcast[T.Adapter.Source]()[]
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

        Skips preparation and upload of a resource whose device copy matches
        its current revision when the world reuses device copies. Every
        other device copy, and every copy the kernel may write, is marked
        unknown before work is queued, so a failure leaves no stale record.
        Mutable adapted sources are prepared on every call.

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
            var reuse = (
                storage._device_copy_current(id)
                and not Self._mutable_adapted[T]
            )
            # Copies the kernel may write are unknown until commit_device.
            if not reuse or Self.spec._mode[T] != 1:
                storage._drop_device_record(id)
            ref source = storage._get_bound[T]()
            ref cache = storage._device_cache[id]
            if cache.context._handle != context._handle:
                raise Error(
                    "Resource cache belongs to a different device context"
                )
            comptime if conforms_to(T, DevicePassableResource):
                comptime assert conforms_to(T, DevicePassableResource)
                if not reuse:
                    cache._uploaded = _TransferStats()
                    cache._downloads.clear()
                    comptime if Self.spec._mode[T] == 1:
                        var view = T.Adapter.prepare_device(
                            Pointer(to=source).unsafe_bitcast[
                                T.Adapter.Source
                            ]()[],
                            cache,
                        )
                        _ = cache._descriptor(view)
                    else:
                        var view = T.Adapter.prepare_device_mutable[
                            Self.spec.access[T]
                        ](
                            Pointer(to=source).unsafe_bitcast[
                                T.Adapter.Source
                            ]()[],
                            cache,
                        )
                        _ = cache._descriptor(view)
                    frame.uploaded.add(cache._uploaded)
                result[i] = rebind[
                    DevicePointer[mut=True, DType.uint8, MutUntrackedOrigin]
                ](cache._buffers[-1].device_ptr())
            else:
                var descriptor = cache._ensure(-1, max(1, size_of[T]()))
                if size_of[T]() > 0 and not reuse:
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

    def commit_device(mut self):
        """Records device copies after successful synchronization and publication.

        Advances the revision of every resource the kernel could write, since
        publication changed its host value. With device copy reuse enabled,
        stamps each device copy with the revision it now matches. Mutable
        adapted sources are never reused, so they receive no record.
        """
        ref storage = self._storage[]
        comptime for i in range(len(Self.spec)):
            comptime T = Self.spec.ResourceTypes[i]
            comptime id = reflect[T].name()
            var revision: UInt64
            comptime if Self.spec._mode[T] != 1:
                revision = storage._touch(id)
            else:
                revision = storage._revision(id)
            comptime if not Self._mutable_adapted[T]:
                if storage._reuse_device and id in storage._device_cache:
                    storage._device_revisions[id] = revision

    def download(mut self, mut frame: _TransferFrame) raises:
        """Stages mutable resource outputs without publishing partial results.

        Plain read_write resources download their bytes. Mutable adapted
        sources stage their outputs through the adapter.

        Args:
            frame: Invocation's staged output owner.

        Raises:
            Error: If enqueueing a resource download fails.
        """
        comptime for i in range(len(Self.spec)):
            comptime T = Self.spec.ResourceTypes[i]
            comptime if Self._mutable_adapted[T]:
                comptime assert conforms_to(T, DevicePassableResource)
                ref source = self._storage[]._get_bound[T]()
                ref cache = self._storage[]._device_cache[reflect[T].name()]
                try:
                    T.Adapter.stage_device_results[Self.spec.access[T]](
                        Pointer(to=source).unsafe_bitcast[T.Adapter.Source]()[],
                        cache,
                    )
                finally:
                    while len(cache._downloads) > 0:
                        frame.downloads.append(cache._downloads.pop())
            elif Self.spec._mode[T] == 3 and size_of[T]() > 0:
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
