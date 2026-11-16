"""The central entry point tying entities, components, and resources together.

Provides `World`, which owns a [..host_storage.HostStorage], a
[..device_storage.DeviceComponentStorage], and a [..resource.ResourceStorage].
"""

from std.sys import has_accelerator
from std.os import abort
from .execution import ThreadedExecutionConfig

from tracy import Zone

from max.gpu.host import DeviceContext

from .component import (
    ComponentType,
)
from .debug_utils import debug_warn
from .host_storage import HostStorage
from .device_storage import DeviceComponentStorage
from .resource import ResourceStorage
from .resource_adapter import _TransferStats
from .filter import Filter, BitMaskFilter
from .spatial import SpatialClassifier, _maintain_spatial
from .unsafe_box import UnsafeBox
from .error import LarecsError
from .entity import EntityAccessor


struct World[*component_types: ComponentType](Copyable, Sized):
    """
    World is the central type holding entity and component data, as well as resources.

    The World provides all the basic ECS functionality of Larecs through it's member [..host_storage.HostStorage storage].
    These include functions like [..host_storage.HostStorage.query], [..host_storage.HostStorage.add_entity], [..host_storage.HostStorage.add], [..host_storage.HostStorage.remove], [..host_storage.HostStorage.get] or [..host_storage.HostStorage.remove_entity].

    Parameters:
        component_types: A variadic list with all possible component types for this world.
    """

    comptime HostStorage = HostStorage[*Self.component_types]
    """The host storage type used by the world."""
    var storage: Self.HostStorage
    """[..host_storage.HostStorage Component Storage] associated with the world."""

    comptime DeviceComponentStorage = DeviceComponentStorage[
        *Self.component_types
    ]
    """The device component storage type used by the world."""
    var _device_storage: Optional[Self.DeviceComponentStorage]
    """[..device_storage.DeviceComponentStorage Component Storage] associated with the world."""

    var _threaded_config: ThreadedExecutionConfig
    """Fixed scheduling policy, preserved by idle copies and moves."""
    var _execution_active: Bool
    """Caller-confined flag protecting threaded invocation lifetimes."""

    var _execution_unusable: Bool
    """Completion health retained even if the public resource table is replaced."""

    var _last_device_upload: _TransferStats
    """Uploads queued by the latest device invocation, for tests and benchmarks."""

    var resources: ResourceStorage  # The resources of the world.
    """[..resource.ResourceStorage Resource Storage] associated with the world."""

    var _spatial_classifier: Optional[UnsafeBox]
    """Owned optional spatial policy; ordinary operations do not consult it."""
    var _spatial_maintenance: Optional[
        def(
            mut storage: Self.HostStorage, classifier: UnsafeBox
        ) thin raises LarecsError
    ]
    """Typed maintenance adapter paired with the policy box."""

    def _check_execution(self) raises:
        """Rejects reentrant execution or unconfirmed prior device completion.

        Raises:
            Error: If threaded execution is active or a prior queue failure
                made this world unusable.
        """
        if self._execution_active:
            raise Error("World execution is already active")
        if self._execution_unusable:
            raise Error("World is unusable after unconfirmed device completion")

    def __init__(
        out self,
        *,
        execution_config: ThreadedExecutionConfig = ThreadedExecutionConfig(),
    ):
        """Creates a world with fixed optional threaded scheduling settings.

        Args:
            execution_config: Scheduling policy; kernels remain sequential unless
                explicitly invoked with ``threaded=True``.
        """
        with Zone(function_name="World.__init__()"):
            self.storage = Self.HostStorage()
            self._threaded_config = execution_config.copy()
            self._execution_active = False
            self._execution_unusable = False
            self._last_device_upload = _TransferStats()
            self._spatial_classifier = None
            self._spatial_maintenance = None

            comptime if not has_accelerator():
                # This build's compilation target has no accelerator
                # support at all -- not merely "no device plugged into
                # this particular machine", which is the runtime condition
                # the `else` branch below handles, but no ability to
                # target a device backend in the first place. `DeviceContext()`
                # would have nothing to succeed at here, so skip constructing
                # it rather than attempting then immediately catching a
                # doomed call: only `self.storage` (host storage) gets built,
                # `self._device_storage` stays empty, and
                # `SystemContext.run(..., on_device=True)` already compiles out
                # its entire device path under this same `has_accelerator()`
                # check (see `system.mojo`), so no device method is reachable
                # from a world built this way.
                self._device_storage = None
            else:
                try:
                    self._device_storage = Self.DeviceComponentStorage(
                        DeviceContext(), 0
                    )
                except e:
                    # No working accelerator at *runtime* is still a
                    # routine, expected condition even on a build that
                    # supports GPU compilation (most hosts don't have one
                    # plugged in), so this constructor -- unlike
                    # `SystemContext.run(..., on_device=True)`, which does
                    # raise a clear error when it actually needs a device --
                    # must not fail outright here just because a device
                    # context could not be created. But it must not stay
                    # silent either: the only sign of this failure from
                    # here on is `self._device_storage` being empty, and
                    # the first thing a caller who *did* expect a device sees
                    # is an unrelated-looking error much later, at the
                    # first `on_device=True` run. Surface the real cause now,
                    # in debug builds, at the point it actually occurred.
                    self._device_storage = None
                    debug_warn(
                        t"World.__init__: device storage did not"
                        t" initialize ({String(e)}); on_device=True system"
                        t" runs will raise until a working accelerator is"
                        t" available."
                    )

            self.resources = ResourceStorage()

    def __init__(out self, *, copy: Self):
        """Copies an idle world and preserves its scheduling policy.

        Args:
            copy: Idle source world; active copies abort unconditionally.
        """
        if copy._execution_active:
            abort("Cannot copy an executing world")
        self.storage = copy.storage.copy()
        self._device_storage = copy._device_storage.copy()
        self._threaded_config = copy._threaded_config.copy()
        self._execution_active = False
        self._execution_unusable = copy._execution_unusable
        self._last_device_upload = _TransferStats()
        self.resources = copy.resources.copy()
        self._spatial_classifier = copy._spatial_classifier.copy()
        self._spatial_maintenance = copy._spatial_maintenance.copy()

    def __init__(out self, *, deinit move: Self):
        """Transfers an idle world, including scheduling policy and device state.

        Args:
            move: Idle source world; active moves abort unconditionally.
        """
        if move._execution_active:
            abort("Cannot move an executing world")
        self.storage = move.storage^
        self._device_storage = move._device_storage^
        self._threaded_config = move._threaded_config^
        self._execution_active = False
        self._execution_unusable = move._execution_unusable
        self._last_device_upload = move._last_device_upload^
        self.resources = move.resources^
        self._spatial_classifier = move._spatial_classifier^
        self._spatial_maintenance = move._spatial_maintenance^

    def __deinit__(deinit self):
        """Rejects destruction or replacement while worker pointers are live."""
        if self._execution_active:
            abort("Cannot destroy an executing world")
        # Mojo destroys unused fields eagerly, even inside __deinit__. Keep
        # every owner alive until the active-invocation check has completed.
        _ = self.storage^
        _ = self._device_storage^
        _ = self.resources^
        _ = self._spatial_classifier^
        _ = self._spatial_maintenance^
        _ = self._threaded_config^

    def execution_config(self) -> ThreadedExecutionConfig:
        """Returns a copy of the world's immutable scheduling policy.

        Returns:
            Settings preserved by idle world copies and moves.
        """
        return self._threaded_config.copy()

    def reuse_device_copies(mut self, enabled: Bool):
        """Lets device runs skip uploading unchanged data (experimental).

        Off by default. Larecs tracks revisions that conservatively advance
        on each Larecs access that may mutate data:

        - Resources: ``add``, ``set``, ``get`` through mutable storage, host
          runs declaring ``write`` or ``read_write``, and device runs
          writing the resource.
        - Component columns, per type and store: ``storage.get``, ``set``,
          ``apply``, kernel runs writing the type, and every structural
          change, spatial reordering, or partition move of the store.

        With reuse enabled, a device run skips uploading a resource or a
        column segment whose device copy matches its current revision.
        Use ``world.resources.read[T]()`` and ``world.storage.read[T](entity)``
        for reads between device runs, since mutable ``get`` counts as a
        mutation.

        Mutations through references obtained before a later Larecs call, or
        through raw pointers, are not detected. Re-obtain references after a
        run, or call ``world.resources.invalidate_device[T]()`` or
        ``invalidate_device_copies()`` after such a mutation; otherwise the
        next device run reads stale values.

        Disabling discards every device copy record. World copies keep the
        setting but start without records.

        Args:
            enabled: Whether device runs may reuse unchanged device copies.
        """
        self.resources._set_reuse_device(enabled)
        if self._device_storage:
            self._device_storage.unsafe_value()._set_reuse(enabled)

    def invalidate_device_copies(mut self):
        """Marks every device copy stale, so the next device run uploads it.

        Call this after mutating world data through escaped references or raw
        pointers in a world that reuses device copies.
        """
        self.resources._invalidate_device_copies()
        if self._device_storage:
            self._device_storage.unsafe_value()._invalidate_records()

    def __len__(self, out size: Int):
        """
        Returns the number of entities in the world.

        Note that this requires iterating over all archetypes and
        may be an expensive operation.

        Returns:
            The number of entities in the world.
        """
        with Zone(function_name="World.__len__(out size: Int)"):
            size = 0
            for archetype in self.storage._archetypes:
                size += len(archetype)

    @staticmethod
    def filter[
        filter: Filter
    ]() -> BitMaskFilter[len(filter._exclude) > 0 or filter._is_exclusive]:
        """
        Returns a bitmask filter for querying entities matching the given filter criteria.

        Note:
            The only use case for this is to create a [..filter.Filter] at comptime, materialize it to make runtime mutations
            and then use it for some ECS operation.

        Parameters:
            filter: The comptime filter specifying which components to match against.

        Returns:
            A bitmask filter representing the query result.
        """
        with Zone(
            function_name=(
                "World.filter[filter: Filter]() ->"
                " BitMaskFilter[len(filter._exclude) > 0 or"
                " filter._is_exclusive]"
            )
        ):
            comptime bitmask = filter.get_bitmask_filter[
                *Self.component_types
            ]()
            return bitmask

    def register_spatial_classifier[
        C: SpatialClassifier, //, filter: Filter
    ](
        mut self,
        var classifier: C,
        *,
        partitioned: Bool = False,
    ) raises LarecsError:
        """Registers the world's single spatial policy without reordering rows.

        Configuration lives in the owned classifier value and is copied when
        the world is copied. Multiple registrations are rejected, including
        disjoint filters, until overlap semantics are defined.

        Parameters:
            C: Policy type with an accessor matching the filter.
            filter: Explicit read-only eligibility and access declaration.

        Args:
            classifier: Policy and configuration transferred into the world.
            partitioned: Use one growable store per cluster instead of row reordering.

        Raises:
            LarecsError: If storage is locked or a policy is already registered.

        Constraints:
            The policy filter must declare no writable components; all included
            and excluded components must belong to this world. The classifier
            Accessor must equal EntityAccessor specialized for this filter.
        """
        comptime assert (
            len(filter._written) == 0
        ), "Spatial classifier filters must be read-only; use Filter.read"
        comptime assert Self.HostStorage.component_manager.contains_components[
            *filter._include.ComponentTypes
        ](), "Spatial classifier includes an unknown world component"
        comptime assert Self.HostStorage.component_manager.contains_components[
            *filter._exclude.ComponentTypes
        ](), "Spatial classifier excludes an unknown world component"
        comptime assert (
            C.Accessor == EntityAccessor[filter]
        ), "Classifier Accessor must match its registration filter"
        self.storage._assert_unlocked()
        if self._spatial_classifier:
            raise Error("A spatial classifier is already registered")
        self.storage._spatial_partitioned = partitioned
        self.storage._spatial_enabled = True
        comptime for i in range(len(Self.component_types)):
            comptime T = Self.component_types[i]
            comptime if filter.includes[T]() != -1:
                self.storage._spatial_inputs.set[True](i)
        self.storage.invalidate_spatial()
        self._spatial_classifier = UnsafeBox(classifier^)
        self._spatial_maintenance = _maintain_spatial[
            filter, C, *Self.component_types
        ]

    def invalidate_spatial(mut self):
        """Requests full classification at the next explicit maintenance boundary.

        Use after external policy configuration changes or untracked raw writes.
        No classification or physical movement happens in this call.
        """
        self.storage.invalidate_spatial()

    def maintain_spatial(mut self) raises LarecsError:
        """Explicitly classifies and groups eligible host rows by key.

        Dirty identities are classified once using their final values. Registration
        and structural changes request a full rebuild; clean calls do no work.
        No registered policy is an unlocked no-op. Queries and selections must
        be released first. Classifier errors leave all archetypes unchanged;
        movement uses typed permutations or partition transfers/compaction
        according to the registered mode (decisions 0009 and 0013).
        Component references must not survive maintenance.

        Raises:
            LarecsError: If storage is locked or classification fails.
        """
        self.storage._assert_unlocked()
        if self._spatial_classifier:
            self._spatial_maintenance.value()(
                self.storage, self._spatial_classifier.value()
            )
