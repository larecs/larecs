from std.builtin.device_passable import DevicePassable, DeviceTypeEncoder
from std.math import ceildiv
from std.sys import has_accelerator
from std.time import perf_counter

from max.gpu.host import DevicePointer

from tracy import Zone

from .world import World
from .component import ComponentType
from .filter import Filter
from .iteration import EntityAccessorIterator
from .unsafe_box import UnsafeBox


trait System(Copyable, Deinitable, Movable):
    """Trait for systems in the scheduler."""

    def initialize[
        *WorldTs: ComponentType
    ](mut self, mut context: SystemContext[*WorldTs]) raises:
        """Optionally initializes the system with the given world.

        Parameters:
            WorldTs: The component types in the world.

        Args:
            context: The SystemContext to access ECS functionality through.
        """
        pass

    def update[
        *WorldTs: ComponentType
    ](mut self, mut context: SystemContext[*WorldTs]) raises:
        """Updates the system with the given world.

        Parameters:
            WorldTs: The component types in the world.

        Args:
            context: The SystemContext to access ECS functionality through.
        """
        ...

    def finalize[
        *WorldTs: ComponentType
    ](mut self, mut context: SystemContext[*WorldTs]) raises:
        """Optionally finalizes the system with the given world.

        Parameters:
            WorldTs: The component types in the world.

        Args:
            context: The SystemContext to access ECS functionality through.
        """
        pass


def _update_system[
    S: System, *WorldTs: ComponentType
](mut system: UnsafeBox, mut context: SystemContext[*WorldTs]) raises:
    """Updates the system with the given world.

    Parameters:
        S: The type of the system.
        WorldTs: The types of the components in the world.

    Args:
        system: The system to update.
        context: The SystemContext to access ECS functionality through.
    """
    with Zone(function_name=String(t"{reflect[S].name()}.update()")):
        ref concrete_system = system.unsafe_get[S]()
        S.update[*WorldTs](concrete_system, context)


def _initialize_system[
    S: System, *WorldTs: ComponentType
](mut system: UnsafeBox, mut context: SystemContext[*WorldTs]) raises:
    """Initializes the system with the given SystemContext.

    Parameters:
        S: The type of the system.
        WorldTs: The types of the components in the world.

    Args:
        system: The system to initialize.
        context: The SystemContext to access ECS functionality through.
    """
    with Zone(function_name=String(t"{reflect[S].name()}.initialize()")):
        ref concrete_system = system.unsafe_get[S]()
        S.initialize[*WorldTs](concrete_system, context)


def _finalize_system[
    S: System, *WorldTs: ComponentType
](mut system: UnsafeBox, mut context: SystemContext[*WorldTs]) raises:
    """Finalizes the system with the given SystemContext.

    Parameters:
        S: The type of the system.
        WorldTs: The types of the components in the world.

    Args:
        system: The system to finalize.
        context: The SystemContext to access ECS functionality through.
    """
    with Zone(function_name=String(t"{reflect[S].name()}.finalize()")):
        ref concrete_system = system.unsafe_get[S]()
        S.finalize[*WorldTs](concrete_system, context)


comptime BLOCK_SIZE = 2**4


@fieldwise_init
struct KernelContext[filter: Filter](Copyable):
    var length: Int32
    var thread_count: Int32

    comptime Columns = Array[
        Pointer[UInt8, MutUntrackedOrigin], len(Self.filter)
    ]
    var _columns: Self.Columns

    def __init__(
        out self,
        var columns: Self.Columns,
        *,
        length: Int32,
        thread_count: Int32,
    ):
        self.length = length
        self.thread_count = thread_count
        self._columns = columns^

    def __iter__(self) -> EntityAccessorIterator[Self.filter]:
        return EntityAccessorIterator[Self.filter](self)


@fieldwise_init
struct HostKernelContext[filter: Filter](Copyable, DevicePassable):
    """Device-passable view of the component columns used by a kernel."""

    comptime device_type = KernelContext[Self.filter]

    @staticmethod
    def get_type_name() -> String:
        """Returns the host type name used in device diagnostics."""
        return "KernelContext"

    var length: Int32
    var thread_count: Int32
    comptime Columns = Array[
        DevicePointer[mut=True, dtype=DType.uint8, origin=MutUntrackedOrigin],
        len(Self.filter),
    ]
    var _columns: Self.Columns

    def __init__(
        out self,
        var columns: Self.Columns,
        *,
        length: Int32,
        thread_count: Int32,
    ):
        self._columns = columns^
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

        var dst = target.unsafe_bitcast[Self.device_type]()

        dst[].length = self.length
        dst[].thread_count = self.thread_count

        dst[]._columns = Array[
            Pointer[UInt8, MutUntrackedOrigin], len(Self.filter)
        ](uninitialized=True)

        comptime for i in range(len(Self.filter)):
            dst[]._columns[i] = self._columns[i].buffer().unsafe_ptr()


@fieldwise_init
struct SystemContext[
    *WorldTs: ComponentType,
](Copyable):
    comptime World = World[*Self.WorldTs]

    var _world: Pointer[Self.World, MutUntrackedOrigin]

    def __init__(out self, ref world: Self.World):
        """Creates a context borrowing the scheduler's world."""
        comptime assert origin_of(world).mut, "world must be mutable"

        self._world = (
            Pointer(to=world)
            .mut_cast[True]()
            .unsafe_origin_cast[MutUntrackedOrigin]()
        )

    def run[
        filter: Filter,
        //,
        KernelFunc: def(KernelContext[filter]) thin -> None,
        *,
        on_gpu: Bool = False,
    ](mut self) raises:
        """Runs a system function over rows matching ``filter``.

        Parameters:
            filter: Compile-time component inclusion and exclusion constraints.
            KernelFunc: The kernel specialized for ``filter``.
            on_gpu: Whether to execute the kernel against device storage.
        """
        var length = 0
        comptime include_mask = filter.get_include_mask[*Self.WorldTs]()
        comptime exclude_mask = filter.get_exclude_mask[*Self.WorldTs]()
        var matching_archetypes = self._world[].storage._get_archetype_iterator(
            include_mask,
            exclude_mask,
        )
        for ref archetype in matching_archetypes.copy():
            length += len(archetype)

        comptime if has_accelerator() and on_gpu:
            ref device_storage = self._world[]._device_storage[]
            self._world[]._device_storage = Self.World.DeviceStorage(
                device_storage._device_context, length
            )

            var kernel_columns = HostKernelContext[filter].Columns(
                uninitialized=True
            )

            comptime for i in range(len(filter)):
                comptime T = filter._include.ComponentTypes[i]

                for ref archetype in matching_archetypes.copy():
                    device_storage.copy_from_host[T](
                        archetype._storage.get_component_span[T]()
                    )

                kernel_columns[i] = device_storage.get_device_ptr[T]()

            var grid_dim = ceildiv(length, BLOCK_SIZE)
            if length > 0:
                var kernel_context = HostKernelContext[filter](
                    kernel_columns^,
                    length=Int32(length),
                    thread_count=Int32(grid_dim * BLOCK_SIZE),
                )
                var start = perf_counter()
                device_storage._device_context.enqueue_function[KernelFunc](
                    kernel_context,
                    grid_dim=grid_dim,
                    block_dim=BLOCK_SIZE,
                )
                print(
                    t"GPU Kernel execution time:"
                    t" {(perf_counter() - start) * 1000} ms"
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

        else:
            # A filter can match multiple archetypes. Run the kernel once per
            # matching archetype so each component pointer refers to a
            # homogeneous SoA range and the accessor's row id remains local to
            # that archetype.
            for ref archetype in matching_archetypes^:
                var kernel_columns = KernelContext[filter].Columns(
                    uninitialized=True
                )

                comptime for i in range(len(filter)):
                    comptime T = filter._include.ComponentTypes[i]
                    kernel_columns[i] = archetype._storage.get_component_ptr[
                        T
                    ]().unsafe_bitcast[UInt8]()

                var kernel_context = KernelContext[filter](
                    kernel_columns^,
                    length=Int32(length),
                    thread_count=1,
                )
                var start = perf_counter()
                KernelFunc(kernel_context)
                print(
                    t"CPU Kernel execution time:"
                    t" {(perf_counter() - start) * 1000} ms"
                )
