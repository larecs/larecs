"""Systems and their host/device execution context.

Provides `System`, the trait implemented by scheduler-managed systems,
`SystemContext`, through which a system accesses the world, and
`KernelContext`, the component/resource view seen by a `SystemContext.run`
kernel on host or device.
"""

from std.builtin.device_passable import DevicePassable, DeviceTypeEncoder
from std.sys import has_accelerator
from std.reflection import reflect_fn

from max.gpu.host import DevicePointer
from max.algorithm import parallelize
from .execution import _ExecutionGuard
from .lock import LockGuard
from .sync import AtomicValue
from .resource_representation import _plain_device_value

from tracy import Zone

from .archetype import Archetype as _Archetype
from .world import World
from .host_storage import _sort_entity_ranges
from .entity import EntityRange
from .error import LarecsError, WorldError
from .component import (
    ComponentType,
    ComponentManager,
    Components,
    constrain_device_safe_components,
)
from .filter import Filter
from .iteration import EntityAccessorIterator
from .unsafe_box import UnsafeBox
from .resource import (
    Resources,
    ResourceType,
    ResourceStorage,
    _drain_failed_device,
    _ResourceInvocation,
    _validate_resource_spec,
)
from .resource_adapter import DevicePassableResource, _TransferFrame
from .device_storage import _Segment
from .gpu_launch import BLOCK_SIZE, gpu_grid_dim
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


@always_inline
def _bind_host_resources[
    required_resources: Resources, origin: MutOrigin
](ref[origin] resources: ResourceStorage) raises -> _ResourceInvocation[
    required_resources, origin
]:
    """Validates, leases, and prepares one synchronous host invocation.

    Parameters:
        required_resources: Ordered source and access declarations.
        origin: Borrow keeping resource storage alive through the invocation.

    Args:
        resources: World-owned source storage.

    Raises:
        Error: If validation or host preparation fails.

    Returns:
        Descriptor owners and source leases retained until explicit release.
    """
    _validate_resource_spec[required_resources, False]()
    var binding = _ResourceInvocation[required_resources, origin](resources)
    binding.bind_host()
    return binding^


@always_inline
def _host_kernel_context[
    filter: Filter,
    required_resources: Resources,
    capture_spec: Captures,
    *WorldTs: ComponentType,
](
    mut archetype: _Archetype[*WorldTs],
    first_row: Int,
    row_count: Int,
    resources: ResourceAccessor[required_resources],
    captures: CaptureAccessor[capture_spec],
) raises -> KernelContext[filter, required_resources, capture_spec]:
    """Prepares one bounded host range using invocation-wide bindings.

    Parameters:
        filter: Component access declarations for this range.
        required_resources: Resource declarations for the invocation.
        capture_spec: Explicit capture declarations for the invocation.
        WorldTs: Component types declared by the world.

    Args:
        archetype: Matching archetype containing the range.
        first_row: First row in the caller-validated range.
        row_count: Exact number of rows to execute.
        resources: Validated resource pointers shared across ranges.
        captures: Bound capture pointers shared across ranges.

    Raises:
        Error: If a declared component column is missing.

    Returns:
        A context with component pointers offset to the range start and local
        row numbering. Its untracked references must not escape execution.
        Revisions of the written columns of the store advance (decision 0021).
    """
    comptime for i in range(len(filter)):
        comptime T = filter._include.ComponentTypes[i]
        comptime if filter.writes[T]:
            archetype._storage._touch_column(
                ComponentManager[*WorldTs].get_id[T]()
            )
    var columns = KernelContext[
        filter, required_resources, capture_spec
    ].Columns(uninitialized=True)
    comptime for i in range(len(filter)):
        comptime T = filter._include.ComponentTypes[i]
        columns[i] = (
            archetype._storage.get_component_ptr[T]()
            .unsafe_offset(first_row)
            .unsafe_bitcast[UInt8]()
        )
    return KernelContext[filter, required_resources, capture_spec](
        columns^,
        resources.copy(),
        capture_columns=captures._pointers.copy(),
        length=Int32(row_count),
        thread_count=1,
    )


def _stage_device_columns[
    filter: Filter, *WorldTs: ComponentType
](
    mut world: World[*WorldTs],
    ranges: List[EntityRange],
    total: Int,
    mut frame: _TransferFrame,
) raises -> List[List[_Segment]]:
    """Uploads the readable columns of matched ranges, skipping unchanged segments.

    Ranges are packed at increasing offsets in the given order. With device
    copy reuse enabled, a readable segment is skipped only if the column's
    previous record at the same position matches its store, incarnation,
    revision, row range, and offset (decision 0021). The records of every
    accessed column are removed before any work is queued.

    Parameters:
        filter: Kernel component access declarations.
        WorldTs: Component types declared by the world.

    Args:
        world: World whose device storage is initialized.
        ranges: Nonempty matched store ranges in packing order.
        total: Sum of the range row counts.
        frame: Invocation staging owner.

    Raises:
        Error: If allocation or transfer fails.

    Returns:
        Per filter position, the segments the column will hold after a
        successful run; empty while reuse is disabled.
    """
    ref device = world._device_storage.unsafe_value()
    device._check_host(world.storage._id)
    comptime column_count = len(filter)
    var records = List[List[_Segment]](capacity=column_count)
    comptime for i in range(len(filter)):
        comptime T = filter._include.ComponentTypes[i]
        comptime id = ComponentManager[*WorldTs].get_id[T]()
        var previous = device._take_records[T]()
        var current = List[_Segment]()
        device.ensure_column[T](total)
        var offset = 0
        for k in range(len(ranges)):
            var rows = ranges[k]
            ref store = world.storage._archetypes.unsafe_get(
                rows.archetype_index
            )
            var skip = False
            if device._reuse:
                var segment = _Segment(
                    rows.archetype_index,
                    store._storage._incarnation,
                    store._storage._column_revision(id),
                    rows.first_row,
                    rows.row_count,
                    offset,
                )
                skip = (
                    segment.incarnation != 0
                    and k < len(previous)
                    and previous[k] == segment
                )
                current.append(segment)
            comptime if filter.reads[T]:
                if not skip:
                    device.stage_from_host[T](
                        frame,
                        Span(
                            unsafe_ptr=store._storage.get_component_ptr[
                                T
                            ]().unsafe_offset(rows.first_row),
                            length=rows.row_count,
                        ),
                        offset=offset,
                    )
            offset += rows.row_count
        records.append(current^)
    return records^


def _commit_device_columns[
    filter: Filter, *WorldTs: ComponentType
](mut world: World[*WorldTs], var records: List[List[_Segment]]):
    """Records device column contents after successful publication.

    Advances the revision of every written column in each matched store,
    since publication changed its host values, then stamps the segments.

    Parameters:
        filter: Kernel component access declarations.
        WorldTs: Component types declared by the world.

    Args:
        world: World whose device storage is initialized.
        records: Segments returned by `_stage_device_columns`.
    """
    ref device = world._device_storage.unsafe_value()
    comptime for i in range(len(filter)):
        comptime T = filter._include.ComponentTypes[i]
        comptime id = ComponentManager[*WorldTs].get_id[T]()
        comptime if filter.writes[T]:
            for segment in records[i]:
                world.storage._archetypes.unsafe_get(
                    segment.store
                )._storage._touch_column(id)
            for ref segment in records[i]:
                segment.revision = world.storage._archetypes.unsafe_get(
                    segment.store
                )._storage._column_revision(id)
        device._restore_records[T](records[i].copy())


def _validate_threaded_spec[
    filter: Filter, required_resources: Resources, capture_spec: Captures
]():
    """Checks eligibility independently of worker count or sequential fallback.

    Parameters:
        filter: Accessed components, excluding filter-only exclusions.
        required_resources: Explicit read-only plain values or adapted sources.
        capture_spec: Must be empty for threaded kernels.

    Constraints:
        Accessed components and ordinary resources must be pointer-free values;
        resources must be read-only, and explicit captures are unsupported.
    """
    comptime assert (
        len(capture_spec) == 0
    ), "Threaded execution does not support captures"
    comptime for i in range(len(filter)):
        comptime assert _plain_device_value[
            filter._include.ComponentTypes[i]
        ](), "Threaded components require pointer-free trivial plain values"
    comptime for i in range(len(required_resources)):
        comptime T = required_resources.ResourceTypes[i]
        comptime assert (
            required_resources._mode[T] == 1
        ), "Threaded resources require explicit read access"
        comptime if not conforms_to(T, DevicePassableResource):
            comptime assert _plain_device_value[T](), (
                "Threaded resources require pointer-free plain values or"
                " KernelView adapters"
            )


def _run_threaded[
    filter: Filter,
    required_resources: Resources,
    capture_spec: Captures,
    KernelFunc: def(
        KernelContext[filter, required_resources, capture_spec]
    ) thin -> None,
    selected: Bool,
    *WorldTs: ComponentType,
](mut world: World[*WorldTs], saved_ranges: List[EntityRange]) raises:
    """Prepares all ranges on the caller, then drains disjoint host jobs and joins.

    Parameters:
        filter: Kernel component access declaration.
        required_resources: Read-only invocation resource declarations.
        capture_spec: Empty capture declaration, retained in the kernel type.
        KernelFunc: Nonraising thin kernel invoked once per prepared context.
        selected: Use saved exact ranges rather than discovering whole stores.
        WorldTs: Component types supported by the world.

    Args:
        world: Caller-confined world, retained until every worker joins.
        saved_ranges: Selection membership; ignored for ordinary execution.

    Raises:
        Error: If execution, resources, ranges, or checked arithmetic are invalid.
        Preparation completes before any kernel writes; worker failures are fatal.
    """
    _validate_threaded_spec[filter, required_resources, capture_spec]()
    world._check_execution()
    var active = _ExecutionGuard(
        Pointer[Bool, MutUntrackedOrigin](
            unsafe_from_address=Int(Pointer(to=world._execution_active))
        )
    )
    var structural_lock = LockGuard(Pointer(to=world.storage._locks))
    var binding = _bind_host_resources[required_resources](world.resources)
    var resources = ResourceAccessor[required_resources](
        binding.pointers.copy()
    )
    var captures = CaptureAccessor[capture_spec]({uninitialized = True})
    var ranges = List[EntityRange]()
    comptime bitmask = filter.get_bitmask_filter[*WorldTs]()
    comptime if selected:
        ranges = saved_ranges.copy()
    else:
        for index in range(len(world.storage._archetypes)):
            ref store = world.storage._archetypes[index]
            if len(store) and bitmask.matches(store.get_mask()):
                ranges.append(EntityRange(index, 0, len(store)))
    var total = 0
    for rows in ranges:
        if rows.archetype_index < 0 or rows.archetype_index >= len(
            world.storage._archetypes
        ):
            raise Error("Invalid threaded store index")
        ref store = world.storage._archetypes[rows.archetype_index]
        if (
            rows.first_row < 0
            or rows.row_count < 0
            or rows.first_row > len(store)
            or rows.row_count > len(store) - rows.first_row
        ):
            raise Error("Invalid threaded row range")
        if not bitmask.matches(store.get_mask()):
            continue
        if rows.row_count > Int(Int64.MAX) - total:
            raise Error("Threaded matched-row count overflows Int")
        total += rows.row_count
    comptime if selected:
        # Validate a sorted copy, preserving whole-range fallback call order.
        var ordered = ranges.copy()
        _sort_entity_ranges(ordered)
        var previous_store = -1
        var previous_end = 0
        for rows in ordered:
            if rows.row_count == 0 or not bitmask.matches(
                world.storage._archetypes[rows.archetype_index].get_mask()
            ):
                continue
            if (
                rows.archetype_index == previous_store
                and rows.first_row < previous_end
            ):
                raise Error("Threaded selected ranges overlap")
            previous_store = rows.archetype_index
            previous_end = rows.first_row + rows.row_count
    var config = world.execution_config()
    var parallel = config.workers() > 1 and total >= config.min_parallel_rows()
    var chunk_size = max(1, total)
    if parallel:
        var target = config.workers() * config.chunks_per_worker()
        chunk_size = max(1, total // target + Int(total % target != 0))
    var contexts = List[
        KernelContext[filter, required_resources, capture_spec]
    ]()
    for rows in ranges:
        if (
            not bitmask.matches(
                world.storage._archetypes[rows.archetype_index].get_mask()
            )
            or rows.row_count == 0
        ):
            continue
        ref store = world.storage._archetypes.unsafe_get(rows.archetype_index)
        var first = rows.first_row
        var remaining = rows.row_count
        while remaining > 0:
            var count = min(chunk_size, remaining)
            if count > Int(Int32.MAX):
                raise Error("Threaded context exceeds Int32 row limit")
            contexts.append(
                _host_kernel_context[filter, required_resources, capture_spec](
                    store, first, count, resources, captures
                )
            )
            first += count
            remaining -= count
    var job_count = len(contexts)
    var workers = min(config.workers(), job_count)
    # Each worker can make one terminal claim after all useful claims.
    if job_count > Int(UInt32.MAX) - workers:
        raise Error("Threaded job cursor would overflow UInt32")
    # Publish write invalidation only after every fallible preparation step.
    # Keep this range predicate synchronized with context preparation above.
    for rows in ranges:
        if rows.row_count > 0 and bitmask.matches(
            world.storage._archetypes[rows.archetype_index].get_mask()
        ):
            world.storage._mark_spatial_range[filter](
                rows.archetype_index, rows.first_row, rows.row_count
            )
    if not parallel or workers <= 1:
        for job in contexts:
            KernelFunc(job)
    else:
        var jobs = contexts.unsafe_ptr()
        var cursor_owner = AtomicValue[UInt32](0)
        var cursor = cursor_owner.write_view()

        def worker(lane: Int) {imm jobs, imm job_count, imm cursor}:
            """Claims jobs dynamically until all prepared contexts are consumed.

            Args:
                lane: Runtime worker-task index; work is allocated by the cursor.
            """
            while True:
                var index = Int(cursor.fetch_add(1))
                if index >= job_count:
                    break
                KernelFunc(jobs[unsafe_offset=index])

        parallelize(worker, workers, workers)
    _ = contexts^
    binding.release()
    _ = structural_lock^
    _ = active^


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
        on_device: Bool = False,
        threaded: Bool = False,
    ](mut self, *bindings: *Bindings) raises:
        """Runs a thin host or device kernel on selected rows matching ``filter``.

        Parameters:
            filter: Kernel filter intersected with saved selection membership.
            required_resources: Resources available to the kernel.
            capture_spec: Explicit read-only and mutable capture slots.
            KernelFunc: Thin kernel function to invoke.
            Bindings: Inferred explicit capture binding types.
            on_device: Whether to pack and execute matching rows on the device.
            threaded: Opt into experimental synchronous host chunk execution.

        Args:
            bindings: Capture bindings in ``capture_spec`` order.

        Raises:
            Error: If the world is unusable or already executing; selected ranges
                are invalid or overlap; bindings or resources are invalid;
                structural lock slots are exhausted; threaded row totals, job
                counts, or context sizes overflow; context preparation fails;
                or device execution fails.
        """
        comptime assert not (
            threaded and on_device
        ), "Threaded and device execution are mutually exclusive"
        comptime if threaded:
            comptime assert (
                len(Bindings) == 0
            ), "Threaded execution does not support captures"
            _run_threaded[
                filter, required_resources, capture_spec, KernelFunc, True
            ](self._world[], self._ranges)
            return
        self._world[]._check_execution()
        _validate_resource_spec[required_resources, on_device]()
        var host_captures = _bind_captures[capture_spec](*bindings)
        comptime if not has_accelerator() or not on_device:
            var resource_binding = _bind_host_resources[required_resources](
                self._world[].resources
            )
            var resource_accessor = ResourceAccessor[required_resources](
                resource_binding.pointers.copy()
            )
            comptime bitmask_filter = filter.get_bitmask_filter[*Self.WorldTs]()
            for selected_range in self._ranges:
                self._world[].storage._mark_spatial_range[filter](
                    selected_range.archetype_index,
                    selected_range.first_row,
                    selected_range.row_count,
                )
                ref archetype = self._world[].storage._archetypes.unsafe_get(
                    selected_range.archetype_index
                )
                if selected_range.row_count == 0 or not bitmask_filter.matches(
                    archetype.get_mask()
                ):
                    continue
                KernelFunc(
                    _host_kernel_context[
                        filter, required_resources, capture_spec
                    ](
                        archetype,
                        selected_range.first_row,
                        selected_range.row_count,
                        resource_accessor,
                        host_captures,
                    )
                )
            resource_binding.release()
        else:
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

            comptime assert constrain_device_safe_components[
                *filter._include.ComponentTypes
            ](), (
                "EntitySelection.run(..., on_device=True) requires every"
                " accessed component type to be device-safe."
            )
            if not self._world[]._device_storage:
                raise Error(
                    "EntitySelection.run(..., on_device=True) requires a"
                    " working device context."
                )

            # Required resources and explicit bindings remain validated even
            # when the range/filter intersection is empty.
            var resource_binding = _ResourceInvocation[
                required_resources, origin_of(self._world[].resources)
            ](self._world[].resources)
            resource_binding.validate_device(
                self._world[]._device_storage[]._device_context
            )
            if total_length == 0:
                resource_binding.release()
                return

            ref device_storage = self._world[]._device_storage[]
            var frame = _TransferFrame(device_storage._device_context)
            var device_captures = DeviceCaptureStorage[capture_spec]()
            try:
                device_captures.prepare(
                    device_storage._device_context, host_captures, frame
                )
                var capture_pointers = HostKernelContext[
                    filter, required_resources, capture_spec
                ].CaptureBuffers(uninitialized=True)
                comptime for i in range(len(capture_spec)):
                    capture_pointers[i] = rebind[
                        DevicePointer[mut=True, DType.uint8, MutUntrackedOrigin]
                    ](device_captures._buffers[i].unsafe_value().device_ptr())
                var resource_pointers = resource_binding.bind_device(
                    device_storage._device_context, frame
                )
                var column_records = _stage_device_columns[filter](
                    self._world[], matching_ranges, total_length, frame
                )
                var kernel_columns = HostKernelContext[
                    filter, required_resources, capture_spec
                ].Columns(uninitialized=True)
                comptime for i in range(len(filter)):
                    comptime T = filter._include.ComponentTypes[i]
                    kernel_columns[i] = device_storage.get_device_ptr[T]()

                var grid_dim = gpu_grid_dim(
                    total_length, device_storage._max_grid_dim
                )
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
                            self._world[].storage._mark_spatial_range[filter](
                                selected_range.archetype_index,
                                selected_range.first_row,
                                selected_range.row_count,
                            )
                            ref archetype = (
                                self._world[].storage._archetypes.unsafe_get(
                                    selected_range.archetype_index
                                )
                            )
                            device_storage.stage_to_host[T](
                                frame,
                                archetype._storage.get_component_ptr[
                                    T
                                ]().unsafe_offset(selected_range.first_row),
                                offset=packed_offset,
                                length=selected_range.row_count,
                            )
                            packed_offset += selected_range.row_count
                resource_binding.download(frame)
                device_captures.copy_back(host_captures, frame)
                device_storage.synchronize()
                frame.publish()
                resource_binding.commit_device()
                _commit_device_columns[filter](self._world[], column_records^)
            except error:
                _drain_failed_device(
                    self._world[].resources,
                    device_storage._device_context,
                    error^,
                    self._world[]._execution_unusable,
                )
            finally:
                resource_binding.release()
                self._world[]._last_device_upload = frame.uploaded.copy()

    def run[
        filter: Filter,
        required_resources: Resources = Resources[](),
        capture_spec: Captures = Captures[](),
        //,
        KernelFunc: def(
            KernelContext[filter, required_resources, capture_spec]
        ) -> None,
        *Bindings: CaptureBindingType,
        on_device: Bool = False,
        threaded: Bool = False,
    ](
        mut self, kernel_func: KernelFunc, *bindings: *Bindings
    ) raises where not on_device:
        """Runs a value-taking host closure on selected matching rows.

        Parameters:
            filter: Kernel filter intersected with saved selection membership.
            required_resources: Resources available to the closure.
            capture_spec: Explicit read-only and mutable capture slots.
            KernelFunc: Inferred unified closure type.
            Bindings: Inferred explicit capture binding types.
            on_device: Must remain false; lexical device captures are unsupported.
            threaded: Must remain false; threaded kernels must be thin.

        Args:
            kernel_func: Closure invoked once per matching selected range.
            bindings: Capture bindings in ``capture_spec`` order.

        Raises:
            Error: If explicit bindings or required resources are invalid.
        """
        comptime assert not threaded, (
            "Threaded execution requires a thin kernel; lexical closures are"
            " unsupported"
        )
        self._world[]._check_execution()
        _validate_resource_spec[required_resources, on_device]()
        var host_captures = _bind_captures[capture_spec](*bindings)
        var resource_binding = _bind_host_resources[required_resources](
            self._world[].resources
        )
        var resource_accessor = ResourceAccessor[required_resources](
            resource_binding.pointers.copy()
        )
        comptime bitmask_filter = filter.get_bitmask_filter[*Self.WorldTs]()
        for selected_range in self._ranges:
            self._world[].storage._mark_spatial_range[filter](
                selected_range.archetype_index,
                selected_range.first_row,
                selected_range.row_count,
            )
            ref archetype = self._world[].storage._archetypes.unsafe_get(
                selected_range.archetype_index
            )
            if selected_range.row_count == 0 or not bitmask_filter.matches(
                archetype.get_mask()
            ):
                continue
            kernel_func(
                _host_kernel_context[filter, required_resources, capture_spec](
                    archetype,
                    selected_range.first_row,
                    selected_range.row_count,
                    resource_accessor,
                    host_captures,
                )
            )

        resource_binding.release()


@fieldwise_init
struct ResourceAccessor[resources: Resources](Copyable):
    """Points to the resource buffers required by a kernel, indexed by
    position in ``resources``.

    Backed by plain byte pointers rather than a [..resource.ResourceStorage]
    reference, so the same representation works both for host kernels
    (pointers into host resource storage) and device kernels (pointers into
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

    comptime _writable[
        T: ResourceType
    ] = not Self.resources._readonly.Types.contains[
        T
    ]() and not Self.resources._writeonly.Types.contains[
        T
    ]()

    def get[
        T: ResourceType
    ](self) -> ref[
        UntrackedOrigin[mut=Self._writable[T]]
    ] T where not conforms_to(T, DevicePassableResource):
        """Gets an ordinary source using its declared access mode.

        Parameters:
            T: The original source type, never the associated view type.

        Returns:
            An immutable read reference or mutable read_write reference.
            References and descriptors must not escape the invocation.

        Constraints:
            T must be declared with read or read_write access.
        """
        comptime id = Self.resources.index_of[T]()
        comptime assert (
            id != -1
        ), "T must be part of the kernel's required_resources"
        comptime assert (
            Self.resources._mode[T] != 2
        ), "Write-only resources provide set, not get"
        return (
            self._pointers[id]
            .unsafe_bitcast[T]()
            .unsafe_mut_cast[Self._writable[T]]()[]
        )

    def get[
        T: DevicePassableResource
    ](self) -> ref[ImmUntrackedOrigin] T.KernelView:
        """Gets a read-only portable view by its original source type.

        Parameters:
            T: The original adapted source type.

        Returns:
            Immutable host-local or device-local KernelView for this invocation.

        Constraints:
            Adapted sources must be declared with read access.
        """
        comptime id = Self.resources.index_of[T]()
        comptime assert (
            id != -1
        ), "T must be part of the kernel's required_resources"
        comptime assert (
            Self.resources._mode[T] == 1
        ), "DevicePassableResource requires read access on both targets"
        return (
            self._pointers[id]
            .unsafe_bitcast[T.KernelView]()
            .unsafe_mut_cast[False]()[]
        )

    def set[T: ResourceType](self, var value: T):
        """Replaces an ordinary source through host write or read_write access.

        Parameters:
            T: Declared ordinary source type.

        Args:
            value: New source value to move into the bound resource.

        Constraints:
            The declaration must permit writing; adapted resources are read only.
        """
        comptime id = Self.resources.index_of[T]()
        comptime assert (
            id != -1
        ), "T must be part of the kernel's required_resources"
        comptime assert (
            Self.resources._mode[T] != 1
        ), "Read resources cannot be set"
        self._pointers[id].unsafe_bitcast[T]()[] = value^


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
        capture_spec: Ordered read-only and mutable host-local capture slots.
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
    """Explicitly bound host-local values available to this kernel."""

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
        # No `Zone` here: this runs as part of the kernel body on the device,
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
        capture_spec: Ordered read-only and mutable host-local capture slots.
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
            capture_pointers: Device pointers to uploaded host-local values.
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

    def select_cluster[
        filter: Filter = Filter()
    ](
        mut self,
        key: UInt64,
        out selection: EntitySelection[Self.world_origin, *Self.WorldTs],
    ) raises LarecsError:
        """Lock exactly the maintained cluster rows matching a component filter.

        Maintenance must be clean when membership is captured. Later writes
        do not change this selection's membership; release it before maintenance.
        Multiple logical archetypes and dense-cluster blocks may contribute.

        Parameters:
            filter: Component filter intersected with the cluster membership.

        Args:
            key: Exact registered classifier key.

        Raises:
            LarecsError: If partition storage is disabled, maintenance is pending,
                storage is locked, or no structural lock is available.

        Returns:
            A locked selection, empty when the maintained cluster has no matches.
        """
        self.world[].storage._assert_unlocked()
        if not self.world[].storage._spatial_partitioned:
            raise Error(
                "Cluster selection requires partitioned spatial storage"
            )
        if (
            self.world[].storage._spatial_full
            or len(self.world[].storage._spatial_dirty) > 0
        ):
            raise Error("Cluster selection requires clean spatial maintenance")
        selection = EntitySelection[Self.world_origin, *Self.WorldTs](
            self.world, List[EntityRange]()
        )
        var bitmask_filter = self.world[].storage.filter[filter]()
        for index in range(len(selection._world[].storage._archetypes)):
            ref block = selection._world[].storage._archetypes[index]
            if block._partition_key and len(block) > 0:
                if (
                    block._partition_key.value() == key
                    and bitmask_filter.matches(block.get_mask())
                ):
                    selection._ranges.append(EntityRange(index, 0, len(block)))

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
        on_device: Bool = False,
        threaded: Bool = False,
    ](mut self, *bindings: *Bindings) raises:
        """Runs a kernel over component rows matching ``filter``.

        Parameters:
            filter: Compile-time component inclusion and exclusion constraints.
            required_resources: Compile-time resources the kernel may access.
            capture_spec: Ordered read-only and mutable host-local capture slots.
            KernelFunc: The kernel specialized for ``filter`` and
                ``required_resources``.
            Bindings: The inferred types of the supplied capture bindings.
            on_device: Whether to execute the kernel against device storage.
            threaded: Opt into experimental synchronous host chunk execution.

        Args:
            bindings: Explicit read-only and mutable bindings in declared slot order.

        Raises:
            Error: If the world is unusable or already executing; bindings or
                required resources are invalid; structural lock slots are
                exhausted; threaded row totals, job counts, or context sizes
                overflow; context preparation fails; or the device execution
                path fails to allocate or synchronize.
        """
        with Zone(
            function_name=String(
                t"SystemContext.run[filter: Filter, required_resources:"
                t" Resources, //, KernelFunc:"
                t" {reflect_fn[KernelFunc].display_name()} , *, on_device:"
                t" Bool]()"
            )
        ):
            comptime assert not (
                threaded and on_device
            ), "Threaded and device execution are mutually exclusive"
            comptime if threaded:
                comptime assert (
                    len(Bindings) == 0
                ), "Threaded execution does not support captures"
                _run_threaded[
                    filter, required_resources, capture_spec, KernelFunc, False
                ](self.world[], List[EntityRange]())
                return
            self.world[]._check_execution()
            _validate_resource_spec[required_resources, on_device]()
            var host_captures = _bind_captures[capture_spec](*bindings)
            comptime if not has_accelerator() or not on_device:
                var resource_binding = _bind_host_resources[required_resources](
                    self.world[].resources
                )
                var resource_accessor = ResourceAccessor[required_resources](
                    resource_binding.pointers.copy()
                )
                comptime bitmask_filter = filter.get_bitmask_filter[
                    *Self.WorldTs
                ]()
                # Fix the invocation boundary and reacquire each archetype by
                # index instead of retaining the list buffer across callbacks.
                var archetype_count = len(self.world[].storage._archetypes)
                for index in range(archetype_count):
                    if (
                        self.world[].storage._spatial_enabled
                        and bitmask_filter.matches(
                            self.world[].storage._archetypes[index].get_mask()
                        )
                    ):
                        self.world[].storage._mark_spatial_range[filter](
                            index,
                            0,
                            len(self.world[].storage._archetypes[index]),
                        )
                    ref archetype = self.world[].storage._archetypes.unsafe_get(
                        index
                    )
                    if len(archetype) == 0 or not bitmask_filter.matches(
                        archetype.get_mask()
                    ):
                        continue
                    KernelFunc(
                        _host_kernel_context[
                            filter, required_resources, capture_spec
                        ](
                            archetype,
                            0,
                            len(archetype),
                            resource_accessor,
                            host_captures,
                        )
                    )
                resource_binding.release()
            else:
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

                # `on_device=True` moves every accessed component and resource
                # across the host/device boundary as raw bytes (see
                # `DeviceComponentStorage`/`DeviceResourceStorage`): the
                # destination is never constructed through `T`'s copy
                # constructor, only `memcpy`'d into. A type with non-trivial
                # state (an owned heap allocation, custom copy/destroy
                # logic) would be silently corrupted or leaked by that copy,
                # so reject it here at compile time rather than at the
                # `DeviceBuffer` call sites below where the failure would be
                # far less legible. Host execution (`on_device=False`) is
                # unaffected -- it never takes this branch.
                comptime assert constrain_device_safe_components[
                    *filter._include.ComponentTypes
                ](), (
                    "SystemContext.run(..., on_device=True) requires every"
                    " accessed component type to be device-safe (conform to"
                    " DeviceComponentType, i.e. TrivialRegisterPassable) for"
                    " raw byte transfer between host and device."
                )

                if not self.world[]._device_storage:
                    raise Error(
                        "SystemContext.run(..., on_device=True) requires a"
                        " working device context, but this world's"
                        " device storage never initialized -- either no"
                        " accelerator is available, or `DeviceContext()`"
                        " construction failed when the world was created."
                        " Run with on_device=False to execute on the host"
                        " instead."
                    )

                # No component columns exist for an unmatched filter. Validate
                # resources without allocating or launching any device work.
                var resource_binding = _ResourceInvocation[
                    required_resources, origin_of(self.world[].resources)
                ](self.world[].resources)
                resource_binding.validate_device(
                    self.world[]._device_storage[]._device_context
                )
                if length == 0:
                    resource_binding.release()
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

                var frame = _TransferFrame(device_storage._device_context)
                var device_captures = DeviceCaptureStorage[capture_spec]()
                try:
                    device_captures.prepare(
                        device_storage._device_context, host_captures, frame
                    )
                    var capture_pointers = HostKernelContext[
                        filter, required_resources, capture_spec
                    ].CaptureBuffers(uninitialized=True)
                    comptime for i in range(len(capture_spec)):
                        capture_pointers[i] = rebind[
                            DevicePointer[
                                mut=True, DType.uint8, MutUntrackedOrigin
                            ]
                        ](
                            device_captures._buffers[i]
                            .unsafe_value()
                            .device_ptr()
                        )
                    var resource_pointers = resource_binding.bind_device(
                        device_storage._device_context, frame
                    )
                    var matched_ranges = List[EntityRange](
                        capacity=len(matching_archetypes._archetype_indices)
                    )
                    for index in matching_archetypes._archetype_indices:
                        matched_ranges.append(
                            EntityRange(
                                index,
                                0,
                                len(
                                    self.world[].storage._archetypes.unsafe_get(
                                        index
                                    )
                                ),
                            )
                        )
                    var column_records = _stage_device_columns[filter](
                        self.world[], matched_ranges, length, frame
                    )
                    var kernel_columns = HostKernelContext[
                        filter, required_resources, capture_spec
                    ].Columns(uninitialized=True)
                    comptime for i in range(len(filter)):
                        comptime T = filter._include.ComponentTypes[i]
                        kernel_columns[i] = device_storage.get_device_ptr[T]()
                    var grid_dim = gpu_grid_dim(
                        length, device_storage._max_grid_dim
                    )
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
                        device_storage._device_context.enqueue_function[
                            KernelFunc
                        ](
                            kernel_context,
                            grid_dim=grid_dim,
                            block_dim=BLOCK_SIZE,
                        )
                        comptime for i in range(len(filter)):
                            comptime T = filter._include.ComponentTypes[i]
                            comptime if filter.writes[T]:
                                var offset = 0
                                for ref archetype in matching_archetypes.copy():
                                    if (
                                        self.world[].storage._spatial_enabled
                                        and not self.world[].storage._spatial_full
                                        and self.world[].storage._spatial_inputs.get(
                                            Self.World.HostStorage.component_manager.get_id[
                                                T
                                            ]()
                                        )
                                    ):
                                        for row in range(len(archetype)):
                                            self.world[].storage._enqueue_spatial_dirty(
                                                archetype.get_entity(row)
                                            )
                                    device_storage.stage_to_host[T](
                                        frame,
                                        archetype._storage.get_component_ptr[
                                            T
                                        ](),
                                        offset=offset,
                                        length=len(archetype),
                                    )
                                    offset += len(archetype)
                            # `T` is read-only for this kernel: nothing on the
                            # device could have changed it, so there is
                            # nothing to download.
                        # Stage resource outputs on the same invocation queue.
                        resource_binding.download(frame)
                    device_captures.copy_back(host_captures, frame)
                    device_storage.synchronize()
                    frame.publish()
                    resource_binding.commit_device()
                    _commit_device_columns[filter](
                        self.world[], column_records^
                    )
                except error:
                    _drain_failed_device(
                        self.world[].resources,
                        device_storage._device_context,
                        error^,
                        self.world[]._execution_unusable,
                    )
                finally:
                    resource_binding.release()
                    self.world[]._last_device_upload = frame.uploaded.copy()

    def run[
        filter: Filter,
        required_resources: Resources = Resources[](),
        capture_spec: Captures = Captures[](),
        //,
        KernelFunc: def(
            KernelContext[filter, required_resources, capture_spec]
        ) -> None,
        *Bindings: CaptureBindingType,
        on_device: Bool = False,
        threaded: Bool = False,
    ](
        mut self, kernel_func: KernelFunc, *bindings: *Bindings
    ) raises where not on_device:
        """Runs a kernel closure over component rows matching ``filter``.

        Parameters:
            filter: Compile-time component inclusion and exclusion constraints.
            required_resources: Compile-time resources the kernel may access.
            capture_spec: Ordered read-only and mutable host-local capture slots.
            KernelFunc: The kernel specialized for ``filter`` and
                ``required_resources``.
            Bindings: The inferred types of the supplied capture bindings.
            on_device: Whether to execute the kernel against device storage.
            threaded: Must remain false; threaded kernels must be thin.

        Args:
            kernel_func: The kernel closure to run once per matching
                archetype. Its context iterates over that archetype's matching
                rows.
            bindings: Explicit read-only and mutable bindings in declared slot order.

        Note:
            Captures may borrow host-local values with ``imm`` or ``mut``.
            Resource access uses the same API as the non-capturing overload.
            This overload executes synchronously on the host only.

        Raises:
            Error: If a required resource is missing.
        """
        with Zone(
            function_name=(
                "SystemContext.run[filter: Filter, required_resources:"
                " Resources, //, KernelFunc: def(KernelContext[filter,"
                " required_resources]) -> None, *, on_device:"
                " Bool](kernel_func: KernelFunc)"
            )
        ):
            comptime assert not threaded, (
                "Threaded execution requires a thin kernel; lexical closures"
                " are unsupported"
            )
            self.world[]._check_execution()
            _validate_resource_spec[required_resources, on_device]()
            var host_captures = _bind_captures[capture_spec](*bindings)
            var resource_binding = _bind_host_resources[required_resources](
                self.world[].resources
            )
            var resource_accessor = ResourceAccessor[required_resources](
                resource_binding.pointers.copy()
            )
            comptime bitmask_filter = filter.get_bitmask_filter[*Self.WorldTs]()
            # Fix the invocation boundary and reacquire each archetype by
            # index instead of retaining the list buffer across callbacks.
            var archetype_count = len(self.world[].storage._archetypes)
            for index in range(archetype_count):
                if (
                    self.world[].storage._spatial_enabled
                    and bitmask_filter.matches(
                        self.world[].storage._archetypes[index].get_mask()
                    )
                ):
                    self.world[].storage._mark_spatial_range[filter](
                        index, 0, len(self.world[].storage._archetypes[index])
                    )
                ref archetype = self.world[].storage._archetypes.unsafe_get(
                    index
                )
                if len(archetype) == 0 or not bitmask_filter.matches(
                    archetype.get_mask()
                ):
                    continue
                kernel_func(
                    _host_kernel_context[
                        filter, required_resources, capture_spec
                    ](
                        archetype,
                        0,
                        len(archetype),
                        resource_accessor,
                        host_captures,
                    )
                )
            resource_binding.release()
