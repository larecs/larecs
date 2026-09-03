from std.builtin.device_passable import DevicePassable, DeviceTypeEncoder
from std.math import ceildiv
from std.sys import has_accelerator

from max.gpu.host import DevicePointer

from tracy import Zone

from .world import World
from .component import ComponentType
from .filter import Filter
from .iteration import EntityAccessorIterator
from .unsafe_box import UnsafeBox
from .resource import (
    Resources,
    ResourceType,
    ResourceStorage,
    DeviceResourceStorage,
)


trait System(Copyable, Deinitable, Movable):
    """Trait for systems in the scheduler."""

    def initialize(mut self, mut context: SystemContext[...]) raises:
        """Optionally initializes the system with the given world.

        Args:
            context: The SystemContext to access ECS functionality through.
        """
        pass

    def update(mut self, mut context: SystemContext[...]) raises:
        """Updates the system with the given world.

        Args:
            context: The SystemContext to access ECS functionality through.
        """
        ...

    def finalize(mut self, mut context: SystemContext[...]) raises:
        """Optionally finalizes the system with the given world.

        Args:
            context: The SystemContext to access ECS functionality through.
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


@fieldwise_init
struct ResourceAccessor[resources: Resources](Copyable):
    """Points to the resource buffers required by a kernel, indexed by
    position in ``resources``.

    Backed by plain byte pointers rather than a [.ResourceStorage]
    reference, so the same representation works both for CPU kernels
    (pointers into host resource storage) and GPU kernels (pointers into
    device buffers uploaded for the call) -- mirroring how ``KernelContext``
    already represents component columns as an array of byte pointers keyed
    by position in the kernel's filter.
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
    var _pointers: Self.Pointers

    def get[T: ResourceType](ref self) -> ref[self] T:
        """Returns the resource of type T.

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
    var length: Int32
    var thread_count: Int32

    comptime Columns = Array[
        Pointer[UInt8, MutUntrackedOrigin], len(Self.filter)
    ]
    var _columns: Self.Columns

    var resources: ResourceAccessor[Self.required_resources]

    def __init__(
        out self,
        var columns: Self.Columns,
        var resources: ResourceAccessor[Self.required_resources],
        *,
        length: Int32,
        thread_count: Int32,
    ):
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
        # No `Zone` here: this runs as part of the kernel body on the GPU,
        # where the host-only Tracy FFI calls are not available.
        return EntityAccessorIterator[Self.filter](self)


@fieldwise_init
struct HostKernelContext[
    filter: Filter, required_resources: Resources = Resources[]()
](Copyable, DevicePassable):
    """Device-passable view of the component columns used by a kernel."""

    comptime device_type = KernelContext[Self.filter, Self.required_resources]

    @staticmethod
    def get_type_name() -> String:
        """Returns the host type name used in device diagnostics."""
        with Zone(function_name="HostKernelContext.get_type_name()"):
            return "KernelContext"

    var length: Int32
    var thread_count: Int32
    comptime Columns = Array[
        DevicePointer[mut=True, dtype=DType.uint8, origin=MutUntrackedOrigin],
        len(Self.filter),
    ]
    var _columns: Self.Columns

    comptime ResourceBuffers = Array[
        DevicePointer[mut=True, dtype=DType.uint8, origin=MutUntrackedOrigin],
        len(Self.required_resources),
    ]
    var _resource_pointers: Self.ResourceBuffers

    def __init__(
        out self,
        var columns: Self.Columns,
        var resource_pointers: Self.ResourceBuffers,
        *,
        length: Int32,
        thread_count: Int32,
    ):
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
    comptime World = World[*Self.WorldTs]

    var world: Pointer[Self.World, Self.world_origin]

    def __init__(out self, ref[Self.world_origin] world: Self.World):
        """Creates a context borrowing the scheduler's world."""
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
                        length=Int32(length),
                        thread_count=1,
                    )
                    KernelFunc(kernel_context)

            else:
                ref device_storage = self.world[]._device_storage[]
                self.world[]._device_storage = Self.World.DeviceStorage(
                    device_storage._device_context, length
                )

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

                    for ref archetype in matching_archetypes.copy():
                        device_storage.copy_from_host[T](
                            archetype._storage.get_component_span[T]()
                        )

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

                        var offset = 0
                        for ref archetype in matching_archetypes.copy():
                            device_storage.copy_to_host[T](
                                archetype._storage.get_component_ptr[T](),
                                offset=offset,
                                length=len(archetype),
                            )
                            offset += len(archetype)

                    device_storage.synchronize()
                    device_resources.synchronize()

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

        Note:
            Resource access through a *capturing* kernel closure has been
            observed to read corrupted data intermittently (tracked as a
            known issue; suspected compiler-level cause around resource
            storage and closures). Until root-caused, ``required_resources``
            is rejected here at compile time. The other ``run`` overload
            (a non-capturing kernel function) does not have this problem --
            use it for resource-reading kernels in the meantime.
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
                    length=Int32(length),
                    thread_count=1,
                )
                kernel_func(kernel_context)
