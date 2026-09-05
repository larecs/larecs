"""Systems and their CPU/GPU execution context.

Provides `System`, the trait implemented by scheduler-managed systems,
`SystemContext`, through which a system accesses the world, and
`KernelContext`, the component/resource view seen by a `SystemContext.run`
kernel on CPU or GPU.
"""

from std.builtin.device_passable import DevicePassable, DeviceTypeEncoder
from std.math import ceildiv
from std.sys import has_accelerator

from max.gpu.host import DevicePointer

from tracy import Zone

from .world import World
from .component import ComponentType, constrain_gpu_safe_components
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
    filter: Filter, required_resources: Resources = Resources[]()
](Copyable):
    """Component columns, resources, and row/thread counts available to a kernel body.

    Parameters:
        filter: The comptime [..filter.Filter] describing the accessed components.
        required_resources: Compile-time resources the kernel may access.
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

    var resources: ResourceAccessor[Self.required_resources]
    """Accessor for the kernel's required resources."""

    def __init__(
        out self,
        var columns: Self.Columns,
        var resources: ResourceAccessor[Self.required_resources],
        *,
        length: Int32,
        thread_count: Int32,
    ):
        """Creates a kernel context from column pointers, resources, and row/thread counts.

        Args:
            columns: Byte pointers to each included component's column.
            resources: Accessor for the kernel's required resources.
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
    filter: Filter, required_resources: Resources = Resources[]()
](Copyable, DevicePassable):
    """Device-passable view of the component columns used by a kernel.

    Parameters:
        filter: The comptime [..filter.Filter] describing the accessed components.
        required_resources: Compile-time resources the kernel may access.
    """

    comptime device_type = KernelContext[Self.filter, Self.required_resources]
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

    def __init__(
        out self,
        var columns: Self.Columns,
        var resource_pointers: Self.ResourceBuffers,
        *,
        length: Int32,
        thread_count: Int32,
    ):
        """Creates a device-passable kernel context.

        Args:
            columns: Device pointers to each included component's column.
            resource_pointers: Device pointers to each required resource's buffer.
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

    def run[
        filter: Filter,
        required_resources: Resources = Resources[](),
        //,
        KernelFunc: def(KernelContext[filter, required_resources]) thin -> None,
        *,
        on_gpu: Bool = False,
    ](mut self) raises:
        """Runs a system function over rows matching ``filter``.

        Parameters:
            filter: Compile-time component inclusion and exclusion constraints.
            required_resources: Compile-time resources the kernel may access.
            KernelFunc: The kernel specialized for ``filter`` and
                ``required_resources``.
            on_gpu: Whether to execute the kernel against device storage.

        Raises:
            Error: If a required resource is missing, or if the device
                execution path fails to allocate or synchronize.
        """
        with Zone(
            function_name=(
                "SystemContext.run[filter: Filter, required_resources:"
                " Resources, //, KernelFunc: def(KernelContext[filter,"
                " required_resources]) thin -> None, *, on_gpu: Bool]()"
            )
        ):
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
                    # `Int(...)` then `unsafe_from_address=`, never
                    # `unsafe_origin_cast` straight off `.get[T]()`'s `ref`:
                    # the latter has been observed to free the resource
                    # early (data corruption, confirmed by experimentation).
                    # This exact construction is stress-tested reliable for
                    # a non-capturing `KernelFunc` (this overload); it is
                    # NOT safe for a capturing closure -- see the guard in
                    # the other `run` overload.
                    resource_pointers[i] = Pointer[UInt8, MutUntrackedOrigin](
                        unsafe_from_address=Int(
                            Pointer(
                                to=self.world[].resources.get[T]()
                            ).unsafe_bitcast[UInt8]()
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
                        filter, required_resources
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
                        filter, required_resources
                    ](
                        kernel_columns^,
                        resource_accessor.copy(),
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
                    " required resource type to be GPU-safe (conform to"
                    " GPUResourceType, i.e. TrivialRegisterPassable) for raw"
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

                var device_resources = DeviceResourceStorage[
                    required_resources
                ](device_storage._device_context)
                var resource_pointers = HostKernelContext[
                    filter, required_resources
                ].ResourceBuffers(uninitialized=True)

                comptime for i in range(len(required_resources)):
                    comptime T = required_resources.ResourceTypes[i]
                    device_resources.upload[T](self.world[].resources.get[T]())
                    resource_pointers[i] = device_resources.get_device_ptr[T]()

                var kernel_columns = HostKernelContext[
                    filter, required_resources
                ].Columns(uninitialized=True)

                comptime for i in range(len(filter)):
                    comptime T = filter._include.ComponentTypes[i]

                    comptime if filter.reads[T]():
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
                        filter, required_resources
                    ](
                        kernel_columns^,
                        resource_pointers^,
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

                        comptime if filter.writes[T]():
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
                        # Same address-round-trip caution as the `upload`
                        # call site above applies here: the `ref`/`mut`
                        # argument must be produced and consumed within this
                        # one call, never routed through a variable.
                        device_resources.download[T](
                            self.world[].resources.get[T]()
                        )

                    # `device_resources` was constructed from
                    # `device_storage._device_context`, so both storages
                    # share the same underlying device context and a single
                    # synchronize flushes every operation enqueued above by
                    # either one.
                    device_storage.synchronize()

    def run[
        filter: Filter,
        required_resources: Resources = Resources[](),
        //,
        KernelFunc: def(KernelContext[filter, required_resources]) -> None,
        *,
        on_gpu: Bool = False,
    ](mut self, kernel_func: KernelFunc) raises where not on_gpu:
        """Runs a system function over rows matching ``filter``.

        Parameters:
            filter: Compile-time component inclusion and exclusion constraints.
            required_resources: Compile-time resources the kernel may access.
                Not yet supported on this overload -- see the note below.
            KernelFunc: The kernel specialized for ``filter`` and
                ``required_resources``.
            on_gpu: Whether to execute the kernel against device storage.

        Args:
            kernel_func: The kernel closure to run once per matching row.

        Note:
            Resource access through a *capturing* kernel closure has been
            observed to read corrupted data intermittently (tracked as a
            known issue; suspected compiler-level cause around resource
            storage and closures). Until root-caused, ``required_resources``
            is rejected here at compile time. The other ``run`` overload
            (a non-capturing kernel function) does not have this problem --
            use it for resource-reading kernels in the meantime.

        Raises:
            Error: If `kernel_func` raises.
        """
        comptime assert len(required_resources) == 0, (
            "SystemContext.run(kernel_func) does not yet support"
            " required_resources on a capturing closure (data corruption"
            " observed) -- use the non-capturing `run[KernelFunc]()`"
            " overload instead."
        )
        with Zone(
            function_name=(
                "SystemContext.run[filter: Filter, required_resources:"
                " Resources, //, KernelFunc: def(KernelContext[filter,"
                " required_resources]) -> None, *, on_gpu:"
                " Bool](kernel_func: KernelFunc)"
            )
        ):
            comptime include_mask = filter.get_include_mask[*Self.WorldTs]()
            comptime exclude_mask = filter.get_exclude_mask[*Self.WorldTs]()
            var matching_archetypes = (
                self.world[].storage._get_archetype_iterator(
                    include_mask,
                    exclude_mask,
                )
            )

            # `required_resources` is asserted empty above, so this is
            # always an empty accessor -- kept as a real (trivial) value
            # rather than special-cased, so `KernelContext`'s shape stays
            # identical to the other `run` overload's.
            var resource_accessor = ResourceAccessor[required_resources](
                ResourceAccessor[required_resources].Pointers(
                    uninitialized=True
                )
            )

            # A filter can match multiple archetypes. Run the kernel once per
            # matching archetype so each component pointer refers to a
            # homogeneous SoA range and the accessor's row id remains local to
            # that archetype.
            for ref archetype in matching_archetypes^:
                var kernel_columns = KernelContext[
                    filter, required_resources
                ].Columns(uninitialized=True)

                comptime for i in range(len(filter)):
                    comptime T = filter._include.ComponentTypes[i]
                    kernel_columns[i] = archetype._storage.get_component_ptr[
                        T
                    ]().unsafe_bitcast[UInt8]()

                var kernel_context = KernelContext[filter, required_resources](
                    kernel_columns^,
                    resource_accessor.copy(),
                    # See the matching comment in the other `run` overload:
                    # each archetype's columns are a separate allocation, so
                    # the row loop must stop at this archetype's own length,
                    # not the total across every matching archetype.
                    length=Int32(len(archetype)),
                    thread_count=1,
                )
                kernel_func(kernel_context)
