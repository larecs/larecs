"""Systems and their CPU/GPU execution context.

Provides `System`, the trait implemented by scheduler-managed systems,
`SystemContext`, through which a system accesses the world, and
`KernelContext`, the component/resource view seen by a `SystemContext.run`
kernel on CPU or GPU.
"""

from std.builtin.device_passable import DevicePassable, DeviceTypeEncoder
from std.math import ceildiv
from std.sys import has_accelerator
from std.reflection import reflect_fn

from max.gpu.host import DevicePointer

from tracy import Zone

from .world import World
from .entity import EntityRange
from .error import LarecsError, WorldError
from .component import (
    ComponentType,
    Components,
    constrain_gpu_safe_components,
)
from .filter import Filter
from .iteration import EntityAccessorIterator
from .unsafe_box import UnsafeBox
from .resource import (
    Resources,
    ResourceType,
    ResourceStorage,
    constrain_gpu_safe_resources,
)
from .device_storage import DeviceResourceStorage
from .capture import (
    Captures,
    CaptureAccessor,
    CaptureBindingType,
    _bind_captures,
    DeviceCaptureStorage,
)
from .component import constrain_components_unique


trait System(Copyable, Deinitable, Movable):
    """Trait for systems in the scheduler."""

    def initialize(mut self, mut context: SystemContext[...]) raises:
        """Optionally initializes the system with the given world.

        Args:
            context: The SystemContext to access ECS functionality through.

        Raises:
            Error: If the implementation raises.
        """
        pass

    def update(mut self, mut context: SystemContext[...]) raises:
        """Updates the system with the given world.

        Args:
            context: The SystemContext to access ECS functionality through.

        Raises:
            Error: If the implementation raises.
        """
        ...

    def finalize(mut self, mut context: SystemContext[...]) raises:
        """Optionally finalizes the system with the given world.

        Args:
            context: The SystemContext to access ECS functionality through.

        Raises:
            Error: If the implementation raises.
        """
        pass


def _update_system[
    S: System, world_origin: MutOrigin, *WorldTs: ComponentType
](
    mut system: UnsafeBox, mut context: SystemContext[world_origin, *WorldTs]
) raises:
    """Updates the system with the given world.

    Parameters:
        S: The type of the system.
        world_origin: The origin of the world borrowed by ``context``. Bound
            explicitly (rather than left inferred) so a specific
            instantiation of this function can be taken as a value and
            stored, e.g. in `Scheduler`'s type-erased system list.
        WorldTs: The types of the components in the world.

    Args:
        system: The system to update.
        context: The SystemContext to access ECS functionality through.
    """
    with Zone(function_name=String(t"{reflect[S].name()}.update()")):
        ref concrete_system = system.unsafe_get[S]()
        S.update(concrete_system, context)


def _initialize_system[
    S: System, world_origin: MutOrigin, *WorldTs: ComponentType
](
    mut system: UnsafeBox, mut context: SystemContext[world_origin, *WorldTs]
) raises:
    """Initializes the system with the given SystemContext.

    Parameters:
        S: The type of the system.
        world_origin: The origin of the world borrowed by ``context``. Bound
            explicitly (rather than left inferred) so a specific
            instantiation of this function can be taken as a value and
            stored, e.g. in `Scheduler`'s type-erased system list.
        WorldTs: The types of the components in the world.

    Args:
        system: The system to initialize.
        context: The SystemContext to access ECS functionality through.
    """
    with Zone(function_name=String(t"{reflect[S].name()}.initialize()")):
        ref concrete_system = system.unsafe_get[S]()
        S.initialize(concrete_system, context)


def _finalize_system[
    S: System, world_origin: MutOrigin, *WorldTs: ComponentType
](
    mut system: UnsafeBox, mut context: SystemContext[world_origin, *WorldTs]
) raises:
    """Finalizes the system with the given SystemContext.

    Parameters:
        S: The type of the system.
        world_origin: The origin of the world borrowed by ``context``. Bound
            explicitly (rather than left inferred) so a specific
            instantiation of this function can be taken as a value and
            stored, e.g. in `Scheduler`'s type-erased system list.
        WorldTs: The types of the components in the world.

    Args:
        system: The system to finalize.
        context: The SystemContext to access ECS functionality through.
    """
    with Zone(function_name=String(t"{reflect[S].name()}.finalize()")):
        ref concrete_system = system.unsafe_get[S]()
        S.finalize(concrete_system, context)


comptime BLOCK_SIZE = 2**4
"""Number of GPU threads per block used when launching kernels."""


struct EntitySelection[
    world_origin: MutOrigin,
    *WorldTs: ComponentType,
](Movable, Sized):
    """Owns exact entity row ranges and one structural-change lock.

    A selection borrows its world, is movable and noncopyable, and keeps the
    world structurally locked until ``release``, destruction, or scope exit.
    A ``with`` block retains the guard and lends a scope-bound selection that
    supports the same kernels and in-place mutations. Kernel runs borrow a
    selection; component mutations update its membership in place while
    retaining the same guard.

    Parameters:
        world_origin: The origin of the borrowed world.
        WorldTs: All component types supported by the world.
    """

    comptime World = World[*Self.WorldTs]
    """The concrete world type borrowed by this selection."""

    var _world: Pointer[Self.World, Self.world_origin]
    var _ranges: List[EntityRange]
    var _lock: Int
    var _owns_lock: Bool

    @doc_hidden
    def __init__(
        out self,
        world: Pointer[Self.World, Self.world_origin],
        var ranges: List[EntityRange],
    ) raises LarecsError:
        """Acquires a structural lock and initializes a selection.

        Args:
            world: The world containing the selected rows.
            ranges: Exact bounded row ranges owned by the selection.

        Raises:
            LarecsError: If no structural lock is available.
        """
        self._world = world
        self._ranges = ranges^
        self._owns_lock = True
        try:
            self._lock = self._world[].storage._locks.lock()
        except:
            raise LarecsError(WorldError.out_of_locks)

    def __deinit__(deinit self):
        """Releases the selection's structural lock exactly once."""
        _ = self._ranges^
        if not self._owns_lock:
            return
        try:
            self._world[].storage._locks.unlock(self._lock)
        except:
            pass

    def __len__(self) -> Int:
        """Returns the number of selected entity rows.

        Returns:
            The sum of all explicit range counts.
        """
        var size = 0
        for entity_range in self._ranges:
            size += entity_range.row_count
        return size

    def release(deinit self):
        """Consumes the selection and releases any directly owned lock.

        Inside a ``with`` block, the context manager retains the lock until
        scope exit even if its borrowed selection is released earlier.
        """
        _ = self._ranges^
        if not self._owns_lock:
            return
        try:
            self._world[].storage._locks.unlock(self._lock)
        except:
            pass

    def __enter__(mut self) -> EntitySelection[origin_of(self), *Self.WorldTs]:
        """Borrows the selection for a scoped batch workflow.

        Returns:
            A noncopyable selection bound to this scope, sharing its existing
            lock. In-place mutations preserve that scope-bound borrow.
        """
        # Narrow the world borrow to this manager's lifetime. The manager
        # retains the origin-bound world pointer and the sole owning guard;
        # the returned selection must not escape that manager.
        return EntitySelection[origin_of(self), *Self.WorldTs](
            self._world.unsafe_origin_cast[origin_of(self)](),
            self._ranges.copy(),
            self._lock,
        )

    @doc_hidden
    def __init__(
        out self,
        world: Pointer[Self.World, Self.world_origin],
        var ranges: List[EntityRange],
        lock: Int,
    ):
        """Creates a scope-bound selection borrowing an existing lock.

        Args:
            world: World borrowed through the owning context manager.
            ranges: Exact selected ranges.
            lock: Lock retained by the owning context manager.
        """
        self._world = world
        self._ranges = ranges^
        self._lock = lock
        self._owns_lock = False

    def __exit__(mut self):
        """Releases the scope's guard on normal, early, or exceptional exit."""
        if self._owns_lock:
            self._world[].storage._unlock(self._lock)
            self._owns_lock = False

    @doc_hidden
    def _is_world_locked(self) -> Bool:
        """Returns whether the borrowed world has any structural lock.

        Returns:
            True when at least one structural guard is active.
        """
        return self._world[].storage._locks.is_locked()

    @doc_hidden
    def _authorizes_structural_change(self) -> Bool:
        """Returns whether this selection owns the world's sole lock.

        Returns:
            True when this selection can authorize a structural mutation.
        """
        return self._world[].storage._locks.owns_only(self._lock)

    def add[
        *Ts: ComponentType, filter: Filter = Filter()
    ](mut self, *components: *Ts) raises LarecsError:
        """Adds components to selected rows matching an optional filter.

        Parameters:
            Ts: Component types to add.
            filter: Additional filter intersected with this selection.

        Args:
            components: Component values copied into every modified row.

        Raises:
            LarecsError: If another structural lock exists or the component
                request is invalid for a candidate row.

        Note:
            Updates this selection to exactly the modified rows, retaining its
            lock. Validation errors leave its membership and lock unchanged.
        """
        comptime assert constrain_components_unique[
            *Ts
        ](), "Duplicate component types in add are not allowed."
        var next_ranges = self._world[].storage._batch_remove_and_add_ranges(
            self._ranges,
            self._world[].storage.filter[filter](),
            Int(Pointer(to=self._world[].storage._locks)),
            self._lock,
            *components,
        )
        self._ranges = next_ranges^

    def remove[
        *Ts: ComponentType, filter: Filter = Filter()
    ](mut self) raises LarecsError:
        """Removes components from selected rows matching an optional filter.

        Parameters:
            Ts: Component types to remove.
            filter: Additional filter intersected with this selection.

        Raises:
            LarecsError: If another structural lock exists or a candidate row
                lacks a removed component.

        Note:
            Updates this selection to exactly the modified rows, retaining its
            lock. Validation errors leave its membership and lock unchanged.
        """
        comptime assert constrain_components_unique[
            *Ts
        ](), "Duplicate component types in remove are not allowed."
        var next_ranges = self._world[].storage._batch_remove_and_add_ranges[
            rem_size=len(Ts),
            remove_ids=Self.World.HostStorage._optional_component_ids[*Ts],
        ](
            self._ranges,
            self._world[].storage.filter[filter](),
            Int(Pointer(to=self._world[].storage._locks)),
            self._lock,
        )
        self._ranges = next_ranges^

    def replace[
        remove: Components,
        filter: Filter = Filter(),
        *AddTs: ComponentType,
    ](mut self, *components: *AddTs) raises LarecsError:
        """Replaces components on selected rows matching an optional filter.

        Parameters:
            remove: Component types to remove before adding replacements.
            filter: Additional filter intersected with this selection.
            AddTs: Inferred component types to add.

        Args:
            components: Replacement values copied into modified rows.

        Raises:
            LarecsError: If another structural lock exists or the component
                request is invalid for a candidate row.

        Note:
            Updates this selection to exactly the modified rows, retaining its
            lock. Validation errors leave its membership and lock unchanged.
        """
        comptime assert constrain_components_unique[
            *remove.ComponentTypes
        ](), "Duplicate component types in replace are not allowed."
        comptime assert constrain_components_unique[
            *AddTs
        ](), "Duplicate replacement component types are not allowed."
        var next_ranges = self._world[].storage._batch_remove_and_add_ranges[
            *AddTs,
            rem_size=len(remove.ComponentTypes),
            remove_ids=Self.World.HostStorage._optional_component_ids[
                *remove.ComponentTypes
            ],
        ](
            self._ranges,
            self._world[].storage.filter[filter](),
            Int(Pointer(to=self._world[].storage._locks)),
            self._lock,
            *components,
        )
        self._ranges = next_ranges^

    def run[
        filter: Filter,
        required_resources: Resources = Resources[](),
        capture_spec: Captures = Captures[](),
        //,
        KernelFunc: def(
            KernelContext[filter, required_resources, capture_spec]
        ) thin -> None,
        *Bindings: CaptureBindingType,
        on_gpu: Bool = False,
    ](mut self, *bindings: *Bindings) raises:
        """Runs a thin CPU or GPU kernel on selected rows matching ``filter``.

        Parameters:
            filter: Kernel filter intersected with saved selection membership.
            required_resources: Resources available to the kernel.
            capture_spec: Explicit read-only and mutable capture slots.
            KernelFunc: Thin kernel function to invoke.
            Bindings: Inferred explicit capture binding types.
            on_gpu: Whether to pack and execute matching rows on the GPU.

        Args:
            bindings: Capture bindings in ``capture_spec`` order.

        Raises:
            Error: If bindings or resources are invalid, or GPU execution fails.
        """
        var host_captures = _bind_captures[capture_spec](*bindings)
        var matching_ranges = List[EntityRange]()
        var total_length = 0
        comptime bitmask_filter = filter.get_bitmask_filter[*Self.WorldTs]()
        for selected_range in self._ranges:
            ref archetype = self._world[].storage._archetypes.unsafe_get(
                selected_range.archetype_index
            )
            if selected_range.row_count > 0 and bitmask_filter.matches(
                archetype.get_mask()
            ):
                matching_ranges.append(selected_range)
                total_length += selected_range.row_count

        comptime if not has_accelerator() or not on_gpu:
            var resource_pointers = ResourceAccessor[
                required_resources
            ].Pointers(uninitialized=True)
            comptime for i in range(len(required_resources)):
                comptime T = required_resources.ResourceTypes[i]
                resource_pointers[i] = Pointer[UInt8, MutUntrackedOrigin](
                    unsafe_from_address=Int(
                        Pointer(to=self._world[].resources.get[T]())
                    )
                )
            var resource_accessor = ResourceAccessor[required_resources](
                resource_pointers^
            )

            for selected_range in matching_ranges:
                ref archetype = self._world[].storage._archetypes.unsafe_get(
                    selected_range.archetype_index
                )
                var kernel_columns = KernelContext[
                    filter, required_resources, capture_spec
                ].Columns(uninitialized=True)
                comptime for i in range(len(filter)):
                    comptime T = filter._include.ComponentTypes[i]
                    kernel_columns[i] = (
                        archetype._storage.get_component_ptr[T]()
                        .unsafe_offset(selected_range.first_row)
                        .unsafe_bitcast[UInt8]()
                    )
                var kernel_context = KernelContext[
                    filter, required_resources, capture_spec
                ](
                    kernel_columns^,
                    resource_accessor.copy(),
                    capture_columns=host_captures._pointers.copy(),
                    length=Int32(selected_range.row_count),
                    thread_count=1,
                )
                KernelFunc(kernel_context)
        else:
            comptime assert constrain_gpu_safe_components[
                *filter._include.ComponentTypes
            ](), (
                "EntitySelection.run(..., on_gpu=True) requires every"
                " accessed component type to be GPU-safe."
            )
            comptime assert constrain_gpu_safe_resources[
                *required_resources.ResourceTypes
            ](), (
                "EntitySelection.run(..., on_gpu=True) requires every"
                " required resource type to be trivially movable."
            )
            if not self._world[]._device_storage:
                raise Error(
                    "EntitySelection.run(..., on_gpu=True) requires a working"
                    " GPU device context."
                )

            # Required resources and explicit bindings remain validated even
            # when the range/filter intersection is empty.
            if total_length == 0:
                comptime for i in range(len(required_resources)):
                    comptime T = required_resources.ResourceTypes[i]
                    _ = Pointer(to=self._world[].resources.get[T]())
                return

            ref device_storage = self._world[]._device_storage[]
            var device_captures = DeviceCaptureStorage[capture_spec](
                device_storage._device_context, host_captures
            )
            var capture_pointers = HostKernelContext[
                filter, required_resources, capture_spec
            ].CaptureBuffers(uninitialized=True)
            comptime for i in range(len(capture_spec)):
                capture_pointers[i] = rebind[
                    DevicePointer[mut=True, DType.uint8, MutUntrackedOrigin]
                ](device_captures._buffers[i].unsafe_value().device_ptr())

            var device_resources = DeviceResourceStorage[required_resources](
                device_storage._device_context
            )
            var resource_pointers = HostKernelContext[
                filter, required_resources, capture_spec
            ].ResourceBuffers(uninitialized=True)
            comptime for i in range(len(required_resources)):
                comptime T = required_resources.ResourceTypes[i]
                device_resources.upload[T](self._world[].resources.get[T]())
                resource_pointers[i] = device_resources.get_device_ptr[T]()

            var kernel_columns = HostKernelContext[
                filter, required_resources, capture_spec
            ].Columns(uninitialized=True)
            comptime for i in range(len(filter)):
                comptime T = filter._include.ComponentTypes[i]
                comptime if filter.reads[T]:
                    var packed_offset = 0
                    for selected_range in matching_ranges:
                        ref archetype = (
                            self._world[].storage._archetypes.unsafe_get(
                                selected_range.archetype_index
                            )
                        )
                        var source = Span(
                            unsafe_ptr=archetype._storage.get_component_ptr[
                                T
                            ]().unsafe_offset(selected_range.first_row),
                            length=selected_range.row_count,
                        )
                        device_storage.copy_from_host[T](
                            source, offset=packed_offset
                        )
                        packed_offset += selected_range.row_count
                else:
                    device_storage.ensure_column[T](total_length)
                kernel_columns[i] = device_storage.get_device_ptr[T]()

            var grid_dim = ceildiv(total_length, BLOCK_SIZE)
            var kernel_context = HostKernelContext[
                filter, required_resources, capture_spec
            ](
                kernel_columns^,
                resource_pointers^,
                capture_pointers=capture_pointers^,
                length=Int32(total_length),
                thread_count=Int32(grid_dim * BLOCK_SIZE),
            )
            device_storage._device_context.enqueue_function[KernelFunc](
                kernel_context,
                grid_dim=grid_dim,
                block_dim=BLOCK_SIZE,
            )

            comptime for i in range(len(filter)):
                comptime T = filter._include.ComponentTypes[i]
                comptime if filter.writes[T]:
                    var packed_offset = 0
                    for selected_range in matching_ranges:
                        ref archetype = (
                            self._world[].storage._archetypes.unsafe_get(
                                selected_range.archetype_index
                            )
                        )
                        device_storage.copy_to_host[T](
                            archetype._storage.get_component_ptr[
                                T
                            ]().unsafe_offset(selected_range.first_row),
                            offset=packed_offset,
                            length=selected_range.row_count,
                        )
                        packed_offset += selected_range.row_count

            comptime for i in range(len(required_resources)):
                comptime T = required_resources.ResourceTypes[i]
                device_resources.download[T](self._world[].resources.get[T]())
            device_captures.copy_back(host_captures)
            device_storage.synchronize()

    def run[
        filter: Filter,
        required_resources: Resources = Resources[](),
        capture_spec: Captures = Captures[](),
        //,
        KernelFunc: def(
            KernelContext[filter, required_resources, capture_spec]
        ) -> None,
        *Bindings: CaptureBindingType,
        on_gpu: Bool = False,
    ](
        mut self, kernel_func: KernelFunc, *bindings: *Bindings
    ) raises where not on_gpu:
        """Runs a value-taking CPU closure on selected matching rows.

        Parameters:
            filter: Kernel filter intersected with saved selection membership.
            required_resources: Resources available to the closure.
            capture_spec: Explicit read-only and mutable capture slots.
            KernelFunc: Inferred unified closure type.
            Bindings: Inferred explicit capture binding types.
            on_gpu: Must remain false; lexical GPU captures are unsupported.

        Args:
            kernel_func: Closure invoked once per matching selected range.
            bindings: Capture bindings in ``capture_spec`` order.

        Raises:
            Error: If explicit bindings or required resources are invalid.
        """
        var host_captures = _bind_captures[capture_spec](*bindings)
        var resource_pointers = ResourceAccessor[required_resources].Pointers(
            uninitialized=True
        )
        comptime for i in range(len(required_resources)):
            comptime T = required_resources.ResourceTypes[i]
            resource_pointers[i] = Pointer[UInt8, MutUntrackedOrigin](
                unsafe_from_address=Int(
                    Pointer(to=self._world[].resources.get[T]())
                )
            )
        var resource_accessor = ResourceAccessor[required_resources](
            resource_pointers^
        )
        comptime bitmask_filter = filter.get_bitmask_filter[*Self.WorldTs]()
        for selected_range in self._ranges:
            ref archetype = self._world[].storage._archetypes.unsafe_get(
                selected_range.archetype_index
            )
            if selected_range.row_count == 0 or not bitmask_filter.matches(
                archetype.get_mask()
            ):
                continue
            var kernel_columns = KernelContext[
                filter, required_resources, capture_spec
            ].Columns(uninitialized=True)
            comptime for i in range(len(filter)):
                comptime T = filter._include.ComponentTypes[i]
                kernel_columns[i] = (
                    archetype._storage.get_component_ptr[T]()
                    .unsafe_offset(selected_range.first_row)
                    .unsafe_bitcast[UInt8]()
                )
            var kernel_context = KernelContext[
                filter, required_resources, capture_spec
            ](
                kernel_columns^,
                resource_accessor.copy(),
                capture_columns=host_captures._pointers.copy(),
                length=Int32(selected_range.row_count),
                thread_count=1,
            )
            kernel_func(kernel_context)


@fieldwise_init
struct ResourceAccessor[resources: Resources](Copyable):
    """Points to the resource buffers required by a kernel, indexed by
    position in ``resources``.

    Backed by plain byte pointers rather than a [..resource.ResourceStorage]
    reference, so the same representation works both for CPU kernels
    (pointers into host resource storage) and GPU kernels (pointers into
    device buffers uploaded for the call) -- mirroring how ``KernelContext``
    already represents component columns as an array of byte pointers keyed
    by position in the kernel's filter.

    Parameters:
        resources: The resource types made available to the kernel.
    """

    # Building one of these pointers from a `ResourceStorage` (Dict /
    # `UnsafeBox`-backed) lookup must go through an address round-trip
    # (`Int(...)` then `unsafe_from_address=`), never `unsafe_origin_cast`:
    # casting the origin of a `ref` sourced that way causes the compiler to
    # free the underlying box early, corrupting the pointer -- confirmed by
    # direct experimentation. See the call sites in `SystemContext.run`.
    comptime Pointers = Array[
        Pointer[UInt8, MutUntrackedOrigin], len(Self.resources)
    ]
    """The type of the per-resource byte pointer array."""
    var _pointers: Self.Pointers
    """Byte pointers to each resource's buffer, indexed by position in ``resources``."""

    def get[T: ResourceType](self) -> ref[MutUntrackedOrigin] T:
        """Returns the resource of type T.

        Always returns a mutable reference, mirroring how
        `EntityAccessor.get` exposes component columns: the backing
        pointer is already untracked-mutable (it addresses either host
        resource storage or an uploaded device buffer), regardless of
        whether this accessor itself was reached through a mutable or
        immutable `KernelContext` -- so a kernel can write a resource back
        even though `KernelFunc`'s non-capturing overload takes its
        `KernelContext` immutably.

        Parameters:
            T: The type of the resource to retrieve.

        Returns:
            The resource of type T.
        """
        comptime id = Self.resources.index_of[T]()
        comptime assert (
            id != -1
        ), "T must be part of the kernel's required_resources"
        return self._pointers[id].unsafe_bitcast[T]()[]


@fieldwise_init
struct KernelContext[
    filter: Filter,
    required_resources: Resources = Resources[](),
    capture_spec: Captures = Captures[](),
](Copyable):
    """Component columns, resources, and row/thread counts available to a kernel body.

    Parameters:
        filter: The comptime [..filter.Filter] describing the accessed components.
        required_resources: Compile-time resources the kernel may access.
        capture_spec: Ordered read-only and mutable CPU-local capture slots.
    """

    var length: Int32
    """Total number of rows the kernel operates over."""
    var thread_count: Int32
    """Number of threads participating in the launch."""

    comptime Columns = Array[
        Pointer[UInt8, MutUntrackedOrigin], len(Self.filter)
    ]
    """The type of the per-component byte pointer array."""
    var _columns: Self.Columns
    """Byte pointers to each included component's column, indexed by position in ``filter``."""

    var captures: CaptureAccessor[Self.capture_spec]
    """Explicitly bound CPU-local values available to this kernel."""

    var resources: ResourceAccessor[Self.required_resources]
    """Accessor for the kernel's required resources."""

    def __init__(
        out self,
        var columns: Self.Columns,
        var resources: ResourceAccessor[Self.required_resources],
        *,
        var capture_columns: Array[
            Pointer[UInt8, MutUntrackedOrigin], len(Self.capture_spec)
        ] = Array[Pointer[UInt8, MutUntrackedOrigin], len(Self.capture_spec)](
            uninitialized=True
        ),
        length: Int32,
        thread_count: Int32,
    ):
        """Creates a kernel context from column pointers, resources, and row/thread counts.

        Args:
            columns: Byte pointers to each included component's column.
            resources: Accessor for the kernel's required resources.
            capture_columns: Pointers to the bound local values.
            length: Total number of rows the kernel operates over.
            thread_count: Number of threads participating in the launch.
        """
        with Zone(
            function_name=(
                "KernelContext.__init__(var columns: Self.Columns, var"
                " resources: ResourceAccessor[Self.required_resources], *,"
                " length: Int32, thread_count: Int32)"
            )
        ):
            self.length = length
            self.thread_count = thread_count
            self._columns = columns^
            self.resources = resources^
            self.captures = CaptureAccessor[Self.capture_spec](capture_columns^)

    def __iter__(self) -> EntityAccessorIterator[Self.filter]:
        """Returns an iterator over the rows matching ``filter``.

        Returns:
            An iterator that yields one row accessor per matching row.
        """
        # No `Zone` here: this runs as part of the kernel body on the GPU,
        # where the host-only Tracy FFI calls are not available.
        return EntityAccessorIterator[Self.filter](self)


@fieldwise_init
struct HostKernelContext[
    filter: Filter,
    required_resources: Resources = Resources[](),
    capture_spec: Captures = Captures[](),
](Copyable, DevicePassable):
    """Device-passable view of the component columns used by a kernel.

    Parameters:
        filter: The comptime [..filter.Filter] describing the accessed components.
        required_resources: Compile-time resources the kernel may access.
        capture_spec: Ordered read-only and mutable CPU-local capture slots.
    """

    comptime device_type = KernelContext[
        Self.filter, Self.required_resources, Self.capture_spec
    ]
    """The device-side type this host context is encoded into."""

    @staticmethod
    def get_type_name() -> String:
        """Returns the host type name used in device diagnostics.

        Returns:
            The type name shown in device diagnostics.
        """
        with Zone(function_name="HostKernelContext.get_type_name()"):
            return "KernelContext"

    var length: Int32
    """Total number of rows the kernel operates over."""
    var thread_count: Int32
    """Number of threads participating in the launch."""
    comptime Columns = Array[
        DevicePointer[mut=True, dtype=DType.uint8, origin=MutUntrackedOrigin],
        len(Self.filter),
    ]
    """The type of the per-component device pointer array."""
    var _columns: Self.Columns
    """Device pointers to each included component's column, indexed by position in ``filter``."""

    comptime ResourceBuffers = Array[
        DevicePointer[mut=True, dtype=DType.uint8, origin=MutUntrackedOrigin],
        len(Self.required_resources),
    ]
    """The type of the per-resource device pointer array."""
    var _resource_pointers: Self.ResourceBuffers
    """Device pointers to each required resource's buffer, indexed by position in ``required_resources``."""

    comptime CaptureBuffers = Array[
        DevicePointer[mut=True, dtype=DType.uint8, origin=MutUntrackedOrigin],
        len(Self.capture_spec),
    ]
    var _capture_pointers: Self.CaptureBuffers

    def __init__(
        out self,
        var columns: Self.Columns,
        var resource_pointers: Self.ResourceBuffers,
        *,
        var capture_pointers: Self.CaptureBuffers = Self.CaptureBuffers(
            uninitialized=True
        ),
        length: Int32,
        thread_count: Int32,
    ):
        """Creates a device-passable kernel context.

        Args:
            columns: Device pointers to each included component's column.
            resource_pointers: Device pointers to each required resource's buffer.
            capture_pointers: Device pointers to uploaded CPU-local values.
            length: Total number of rows the kernel operates over.
            thread_count: Number of threads participating in the launch.
        """
        with Zone(
            function_name=(
                "HostKernelContext.__init__(var columns: Self.Columns, var"
                " resource_pointers: Self.ResourceBuffers, *, length: Int32,"
                " thread_count: Int32)"
            )
        ):
            self._columns = columns^
            self._resource_pointers = resource_pointers^
            self._capture_pointers = capture_pointers^
            self.length = length
            self.thread_count = thread_count

    def _to_device_type[
        Encoder: DeviceTypeEncoder
    ](
        self,
        mut encoder: Encoder,
        target: Pointer[mut=True, T=NoneType, origin=_],
    ):
        """Encodes device buffers as their device-side pointer fields."""
        with Zone(
            function_name=(
                "HostKernelContext._to_device_type[Encoder:"
                " DeviceTypeEncoder](mut encoder: Encoder, target:"
                " Pointer[mut=True, T=NoneType, origin=_])"
            )
        ):
            var dst = target.unsafe_bitcast[Self.device_type]()

            dst[].length = self.length
            dst[].thread_count = self.thread_count

            dst[]._columns = Array[
                Pointer[UInt8, MutUntrackedOrigin], len(Self.filter)
            ](uninitialized=True)

            comptime for i in range(len(Self.filter)):
                dst[]._columns[i] = self._columns[i].buffer().unsafe_ptr()

            var resource_pointers = Array[
                Pointer[UInt8, MutUntrackedOrigin],
                len(Self.required_resources),
            ](uninitialized=True)

            comptime for i in range(len(Self.required_resources)):
                resource_pointers[i] = (
                    self._resource_pointers[i].buffer().unsafe_ptr()
                )

            dst[].resources = ResourceAccessor[Self.required_resources](
                resource_pointers^
            )

            var capture_columns = Array[
                Pointer[UInt8, MutUntrackedOrigin], len(Self.capture_spec)
            ](uninitialized=True)
            comptime for i in range(len(Self.capture_spec)):
                capture_columns[i] = (
                    self._capture_pointers[i].buffer().unsafe_ptr()
                )
            dst[].captures = CaptureAccessor[Self.capture_spec](
                capture_columns^
            )


@fieldwise_init
struct SystemContext[
    world_origin: MutOrigin,
    *WorldTs: ComponentType,
](Copyable):
    """Gives a system access to the world's entities, components, and resources.

    Parameters:
        world_origin: The origin of the world borrowed by this context.
        WorldTs: A variadic list with all possible component types for the world.
    """

    comptime World = World[*Self.WorldTs]
    """The concrete world type this context wraps."""

    var world: Pointer[Self.World, Self.world_origin]
    """Pointer to the world borrowed by the scheduler."""

    def __init__(out self, ref[Self.world_origin] world: Self.World):
        """Creates a context borrowing the scheduler's world.

        Args:
            world: The world to borrow.
        """
        with Zone(
            function_name="SystemContext.__init__(ref world: Self.World)"
        ):
            comptime assert origin_of(world).mut, "world must be mutable"

            self.world = Pointer(to=world)

    @doc_hidden
    def _empty_selection(
        mut self,
        out selection: EntitySelection[Self.world_origin, *Self.WorldTs],
    ) raises LarecsError:
        """Creates an empty locked selection for ownership validation.

        Raises:
            LarecsError: If no structural lock is available.

        Returns:
            An empty selection borrowing this context's world.
        """
        selection = EntitySelection[Self.world_origin, *Self.WorldTs](
            self.world, List[EntityRange]()
        )

    def _select[
        filter: Filter
    ](
        mut self,
        out selection: EntitySelection[Self.world_origin, *Self.WorldTs],
    ) raises LarecsError:
        """Locks and snapshots bounded ranges matching ``filter``.

        Parameters:
            filter: Compile-time filter selecting whole source archetypes.

        Raises:
            LarecsError: If the world is already locked or no lock is available.

        Returns:
            A locked selection of the currently matching rows.
        """
        self.world[].storage._assert_unlocked()
        selection = EntitySelection[Self.world_origin, *Self.WorldTs](
            self.world, List[EntityRange]()
        )
        var bitmask_filter = self.world[].storage.filter[filter]()
        for archetype_index in range(
            len(selection._world[].storage._archetypes)
        ):
            ref archetype = selection._world[].storage._archetypes.unsafe_get(
                archetype_index
            )
            if archetype and bitmask_filter.matches(archetype.get_mask()):
                selection._ranges.append(
                    EntityRange(archetype_index, 0, len(archetype))
                )

    def add_entities[
        *Ts: ComponentType
    ](
        mut self,
        *components: *Ts,
        count: Int,
        out selection: EntitySelection[Self.world_origin, *Self.WorldTs],
    ) raises LarecsError:
        """Creates a batch and returns exactly its rows as a locked selection.

        Parameters:
            Ts: Component types assigned to every new entity.

        Args:
            components: Initial component values copied into every new row.
            count: Number of entities to create.

        Raises:
            LarecsError: If ``count`` is negative, the world is locked, or no
                structural lock is available.

        Returns:
            A locked selection containing only the newly created rows.
        """
        comptime assert constrain_components_unique[
            *Ts
        ](), "Duplicate component types in add_entities are not allowed."
        if count < 0:
            raise LarecsError(WorldError.negative_count)
        self.world[].storage._assert_unlocked()
        selection = EntitySelection[Self.world_origin, *Self.WorldTs](
            self.world, List[EntityRange]()
        )
        if count == 0:
            return

        comptime component_count = len(Ts)
        var archetype_index: Int
        comptime if component_count:
            archetype_index = selection._world[].storage._get_archetype_index(
                selection._world[].storage.component_manager.get_id_arr[*Ts]()
            )
        else:
            archetype_index = 0
        var first_row = selection._world[].storage._create_entities(
            archetype_index, count
        )
        ref archetype = selection._world[].storage._archetypes.unsafe_get(
            archetype_index
        )
        comptime for i in range(component_count):
            comptime T = Ts[i]
            archetype.init_component_range[T](first_row, count, components[i])
        selection._ranges.append(EntityRange(archetype_index, first_row, count))

    def add[
        *Ts: ComponentType, filter: Filter
    ](
        mut self,
        *components: *Ts,
        out selection: EntitySelection[Self.world_origin, *Self.WorldTs],
    ) raises LarecsError:
        """Adds components to all rows matching ``filter``.

        Parameters:
            Ts: Component types to add.
            filter: Compile-time operation filter.

        Args:
            components: Values copied into every modified row.

        Raises:
            LarecsError: If the world is locked or the request is invalid.

        Returns:
            A locked selection containing exactly the modified rows.
        """
        var candidates = self._select[filter]()
        candidates.add(*components)
        selection = candidates^

    def remove[
        *Ts: ComponentType, filter: Filter
    ](
        mut self,
        out selection: EntitySelection[Self.world_origin, *Self.WorldTs],
    ) raises LarecsError:
        """Removes components from all rows matching ``filter``.

        Parameters:
            Ts: Component types to remove.
            filter: Compile-time operation filter.

        Raises:
            LarecsError: If the world is locked or the request is invalid.

        Returns:
            A locked selection containing exactly the modified rows.
        """
        var candidates = self._select[filter]()
        candidates.remove[*Ts]()
        selection = candidates^

    def replace[
        remove: Components,
        filter: Filter,
        *AddTs: ComponentType,
    ](
        mut self,
        *components: *AddTs,
        out selection: EntitySelection[Self.world_origin, *Self.WorldTs],
    ) raises LarecsError:
        """Replaces components on all rows matching ``filter``.

        Parameters:
            remove: Component types to remove.
            filter: Compile-time operation filter.
            AddTs: Inferred replacement component types.

        Args:
            components: Values copied into every modified row.

        Raises:
            LarecsError: If the world is locked or the request is invalid.

        Returns:
            A locked selection containing exactly the modified rows.
        """
        var candidates = self._select[filter]()
        candidates.replace[remove=remove](*components)
        selection = candidates^

    def run[
        filter: Filter,
        required_resources: Resources = Resources[](),
        capture_spec: Captures = Captures[](),
        //,
        KernelFunc: def(
            KernelContext[filter, required_resources, capture_spec]
        ) thin -> None,
        *Bindings: CaptureBindingType,
        on_gpu: Bool = False,
    ](mut self, *bindings: *Bindings) raises:
        """Runs a kernel over component rows matching ``filter``.

        Parameters:
            filter: Compile-time component inclusion and exclusion constraints.
            required_resources: Compile-time resources the kernel may access.
            capture_spec: Ordered read-only and mutable CPU-local capture slots.
            KernelFunc: The kernel specialized for ``filter`` and
                ``required_resources``.
            Bindings: The inferred types of the supplied capture bindings.
            on_gpu: Whether to execute the kernel against device storage.

        Args:
            bindings: Explicit read-only and mutable bindings in declared slot order.

        Raises:
            Error: If a required resource is missing, or if the device
                execution path fails to allocate or synchronize.
        """
        with Zone(
            function_name=String(
                t"SystemContext.run[filter: Filter, required_resources:"
                t" Resources, //, KernelFunc:"
                t" {reflect_fn[KernelFunc].display_name()} , *, on_gpu: Bool]()"
            )
        ):
            var host_captures = _bind_captures[capture_spec](*bindings)
            var length = 0
            comptime include_mask = filter.get_include_mask[*Self.WorldTs]()
            comptime exclude_mask = filter.get_exclude_mask[*Self.WorldTs]()
            var matching_archetypes = (
                self.world[].storage._get_archetype_iterator(
                    include_mask,
                    exclude_mask,
                )
            )
            for ref archetype in matching_archetypes.copy():
                length += len(archetype)

            comptime if not has_accelerator() or not on_gpu:
                var resource_pointers = ResourceAccessor[
                    required_resources
                ].Pointers(uninitialized=True)

                comptime for i in range(len(required_resources)):
                    comptime T = required_resources.ResourceTypes[i]
                    resource_pointers[i] = Pointer[UInt8, MutUntrackedOrigin](
                        unsafe_from_address=Int(
                            Pointer(to=self.world[].resources.get[T]())
                        )
                    )

                var resource_accessor = ResourceAccessor[required_resources](
                    resource_pointers^
                )

                # A filter can match multiple archetypes. Run the kernel once
                # per matching archetype so each component pointer refers to a
                # homogeneous SoA range and the accessor's row id remains
                # local to that archetype.
                for ref archetype in matching_archetypes^:
                    var kernel_columns = KernelContext[
                        filter, required_resources, capture_spec
                    ].Columns(uninitialized=True)

                    comptime for i in range(len(filter)):
                        comptime T = filter._include.ComponentTypes[i]
                        kernel_columns[
                            i
                        ] = archetype._storage.get_component_ptr[
                            T
                        ]().unsafe_bitcast[
                            UInt8
                        ]()

                    var kernel_context = KernelContext[
                        filter, required_resources, capture_spec
                    ](
                        kernel_columns^,
                        resource_accessor.copy(),
                        capture_columns=host_captures._pointers.copy(),
                        # Each archetype's columns are separate SoA
                        # allocations, not offsets into one shared buffer
                        # (unlike the GPU path below, which flattens every
                        # matching archetype into one device column). The
                        # kernel's row loop must therefore stop at this
                        # archetype's own length, not the total across every
                        # matching archetype -- using the total here made
                        # every archetype but the largest walk past the end
                        # of its columns.
                        length=Int32(len(archetype)),
                        thread_count=1,
                    )
                    KernelFunc(kernel_context)

            else:
                # `on_gpu=True` moves every accessed component and resource
                # across the host/device boundary as raw bytes (see
                # `DeviceComponentStorage`/`DeviceResourceStorage`): the
                # destination is never constructed through `T`'s copy
                # constructor, only `memcpy`'d into. A type with non-trivial
                # state (an owned heap allocation, custom copy/destroy
                # logic) would be silently corrupted or leaked by that copy,
                # so reject it here at compile time rather than at the
                # `DeviceBuffer` call sites below where the failure would be
                # far less legible. Host execution (`on_gpu=False`) is
                # unaffected -- it never takes this branch.
                comptime assert constrain_gpu_safe_components[
                    *filter._include.ComponentTypes
                ](), (
                    "SystemContext.run(..., on_gpu=True) requires every"
                    " accessed component type to be GPU-safe (conform to"
                    " GPUComponentType, i.e. TrivialRegisterPassable) for raw"
                    " byte transfer between host and device."
                )
                comptime assert constrain_gpu_safe_resources[
                    *required_resources.ResourceTypes
                ](), (
                    "SystemContext.run(..., on_gpu=True) requires every"
                    " required resource type to be trivially movable for raw"
                    " byte transfer between host and device."
                )

                if not self.world[]._device_storage:
                    raise Error(
                        "SystemContext.run(..., on_gpu=True) requires a"
                        " working GPU device context, but this world's"
                        " device storage never initialized -- either no"
                        " accelerator is available, or `DeviceContext()`"
                        " construction failed when the world was created."
                        " Run with on_gpu=False to execute on the CPU"
                        " instead."
                    )

                # No component columns exist for an unmatched filter. Validate
                # resources without allocating or launching any device work.
                if length == 0:
                    comptime for i in range(len(required_resources)):
                        comptime T = required_resources.ResourceTypes[i]
                        _ = Pointer(to=self.world[].resources.get[T]())
                    return

                # Reuse the world's device storage across calls instead of
                # discarding it: `DeviceComponentStorage.copy_from_host`
                # already grows each column lazily as needed, so replacing
                # the whole storage here on every call threw away every
                # column already resident on the device (forcing a full
                # reallocation and re-upload every time) for no benefit.
                # This also makes `device_storage` a genuine reference for
                # the rest of this branch, rather than one that is
                # immediately invalidated by the reassignment that used to
                # follow it.
                ref device_storage = self.world[]._device_storage[]

                var device_captures = DeviceCaptureStorage[capture_spec](
                    device_storage._device_context, host_captures
                )
                var capture_pointers = HostKernelContext[
                    filter, required_resources, capture_spec
                ].CaptureBuffers(uninitialized=True)
                comptime for i in range(len(capture_spec)):
                    capture_pointers[i] = rebind[
                        DevicePointer[mut=True, DType.uint8, MutUntrackedOrigin]
                    ](device_captures._buffers[i].unsafe_value().device_ptr())

                var device_resources = DeviceResourceStorage[
                    required_resources
                ](device_storage._device_context)
                var resource_pointers = HostKernelContext[
                    filter, required_resources, capture_spec
                ].ResourceBuffers(uninitialized=True)

                comptime for i in range(len(required_resources)):
                    comptime T = required_resources.ResourceTypes[i]
                    device_resources.upload[T](self.world[].resources.get[T]())
                    resource_pointers[i] = device_resources.get_device_ptr[T]()

                var kernel_columns = HostKernelContext[
                    filter, required_resources, capture_spec
                ].Columns(uninitialized=True)

                comptime for i in range(len(filter)):
                    comptime T = filter._include.ComponentTypes[i]

                    comptime if filter.reads[T]:
                        # A filter can match multiple archetypes; each is a
                        # separate homogeneous host range that must land at
                        # its own offset in the flat device column,
                        # matching how the download loop below reads them
                        # back. Uploading every archetype at the default
                        # `offset=0` would overwrite each archetype with
                        # the next, corrupting every column but the last.
                        var offset = 0
                        for ref archetype in matching_archetypes.copy():
                            device_storage.copy_from_host[T](
                                archetype._storage.get_component_span[T](),
                                offset=offset,
                            )
                            offset += len(archetype)
                    else:
                        # `T` is write-only for this kernel: its prior
                        # value is never read, so there is nothing to
                        # upload. The column still needs to exist and be
                        # sized for `length`, since the kernel writes
                        # through it and the download loop below reads the
                        # result back.
                        device_storage.ensure_column[T](length)

                    kernel_columns[i] = device_storage.get_device_ptr[T]()

                var grid_dim = ceildiv(length, BLOCK_SIZE)
                if length > 0:
                    var kernel_context = HostKernelContext[
                        filter, required_resources, capture_spec
                    ](
                        kernel_columns^,
                        resource_pointers^,
                        capture_pointers=capture_pointers^,
                        length=Int32(length),
                        thread_count=Int32(grid_dim * BLOCK_SIZE),
                    )
                    device_storage._device_context.enqueue_function[KernelFunc](
                        kernel_context,
                        grid_dim=grid_dim,
                        block_dim=BLOCK_SIZE,
                    )

                    comptime for i in range(len(filter)):
                        comptime T = filter._include.ComponentTypes[i]

                        comptime if filter.writes[T]:
                            var offset = 0
                            for ref archetype in matching_archetypes.copy():
                                device_storage.copy_to_host[T](
                                    archetype._storage.get_component_ptr[T](),
                                    offset=offset,
                                    length=len(archetype),
                                )
                                offset += len(archetype)
                        # `T` is read-only for this kernel: nothing on the
                        # device could have changed it, so there is
                        # nothing to download.

                    comptime for i in range(len(required_resources)):
                        comptime T = required_resources.ResourceTypes[i]
                        device_resources.download[T](
                            self.world[].resources.get[T]()
                        )

                    # `device_resources` was constructed from
                    # `device_storage._device_context`, so both storages
                    # share the same underlying device context and a single
                    # synchronize flushes every operation enqueued above by
                    # either one.
                    device_captures.copy_back(host_captures)
                device_storage.synchronize()

    def run[
        filter: Filter,
        required_resources: Resources = Resources[](),
        capture_spec: Captures = Captures[](),
        //,
        KernelFunc: def(
            KernelContext[filter, required_resources, capture_spec]
        ) -> None,
        *Bindings: CaptureBindingType,
        on_gpu: Bool = False,
    ](
        mut self, kernel_func: KernelFunc, *bindings: *Bindings
    ) raises where not on_gpu:
        """Runs a kernel closure over component rows matching ``filter``.

        Parameters:
            filter: Compile-time component inclusion and exclusion constraints.
            required_resources: Compile-time resources the kernel may access.
            capture_spec: Ordered read-only and mutable CPU-local capture slots.
            KernelFunc: The kernel specialized for ``filter`` and
                ``required_resources``.
            Bindings: The inferred types of the supplied capture bindings.
            on_gpu: Whether to execute the kernel against device storage.

        Args:
            kernel_func: The kernel closure to run once per matching
                archetype. Its context iterates over that archetype's matching
                rows.
            bindings: Explicit read-only and mutable bindings in declared slot order.

        Note:
            Captures may borrow CPU-local values with ``imm`` or ``mut``.
            Resource access uses the same API as the non-capturing overload.
            This overload executes synchronously on the CPU only.

        Raises:
            Error: If a required resource is missing.
        """
        with Zone(
            function_name=(
                "SystemContext.run[filter: Filter, required_resources:"
                " Resources, //, KernelFunc: def(KernelContext[filter,"
                " required_resources]) -> None, *, on_gpu:"
                " Bool](kernel_func: KernelFunc)"
            )
        ):
            var host_captures = _bind_captures[capture_spec](*bindings)
            comptime include_mask = filter.get_include_mask[*Self.WorldTs]()
            comptime exclude_mask = filter.get_exclude_mask[*Self.WorldTs]()
            var matching_archetypes = (
                self.world[].storage._get_archetype_iterator(
                    include_mask,
                    exclude_mask,
                )
            )

            var resource_pointers = ResourceAccessor[
                required_resources
            ].Pointers(uninitialized=True)
            comptime for i in range(len(required_resources)):
                comptime T = required_resources.ResourceTypes[i]
                resource_pointers[i] = Pointer[UInt8, MutUntrackedOrigin](
                    unsafe_from_address=Int(
                        Pointer(to=self.world[].resources.get[T]())
                    )
                )

            var resource_accessor = ResourceAccessor[required_resources](
                resource_pointers^
            )

            # A filter can match multiple archetypes. Run the kernel once per
            # matching archetype so each component pointer refers to a
            # homogeneous SoA range and the accessor's row id remains local to
            # that archetype.
            for ref archetype in matching_archetypes^:
                var kernel_columns = KernelContext[
                    filter, required_resources, capture_spec
                ].Columns(uninitialized=True)

                comptime for i in range(len(filter)):
                    comptime T = filter._include.ComponentTypes[i]
                    kernel_columns[i] = archetype._storage.get_component_ptr[
                        T
                    ]().unsafe_bitcast[UInt8]()

                var kernel_context = KernelContext[
                    filter, required_resources, capture_spec
                ](
                    kernel_columns^,
                    resource_accessor.copy(),
                    capture_columns=host_captures._pointers.copy(),
                    # See the matching comment in the other `run` overload:
                    # each archetype's columns are a separate allocation, so
                    # the row loop must stop at this archetype's own length,
                    # not the total across every matching archetype.
                    length=Int32(len(archetype)),
                    thread_count=1,
                )
                kernel_func(kernel_context)
