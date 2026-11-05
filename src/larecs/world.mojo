"""The central entry point tying entities, components, and resources together.

Provides `World`, which owns a [..host_storage.HostStorage], a
[..device_storage.DeviceComponentStorage], and a [..resource.ResourceStorage].
"""

from std.sys import has_accelerator

from tracy import Zone

from max.gpu.host import DeviceContext

from .component import (
    ComponentType,
)
from .debug_utils import debug_warn
from .host_storage import HostStorage
from .device_storage import DeviceComponentStorage
from .resource import ResourceStorage
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

    def __init__(out self):
        """
        Creates a new [.World].
        """
        with Zone(function_name="World.__init__()"):
            self.storage = Self.HostStorage()
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
                # `SystemContext.run(..., on_gpu=True)` already compiles out
                # its entire device path under this same `has_accelerator()`
                # check (see `system.mojo`), so no GPU method is reachable
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
                    # `SystemContext.run(..., on_gpu=True)`, which does
                    # raise a clear error when it actually needs a device --
                    # must not fail outright here just because a device
                    # context could not be created. But it must not stay
                    # silent either: the only sign of this failure from
                    # here on is `self._device_storage` being empty, and
                    # the first thing a caller who *did* expect a GPU sees
                    # is an unrelated-looking error much later, at the
                    # first `on_gpu=True` run. Surface the real cause now,
                    # in debug builds, at the point it actually occurred.
                    self._device_storage = None
                    debug_warn(
                        t"World.__init__: GPU device storage did not"
                        t" initialize ({String(e)}); on_gpu=True system"
                        t" runs will raise until a working accelerator is"
                        t" available."
                    )

            self.resources = ResourceStorage()

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
    ](mut self, var classifier: C) raises LarecsError:
        """Registers the world's single spatial policy without reordering rows.

        Configuration lives in the owned classifier value and is copied when
        the world is copied. Multiple registrations are rejected, including
        disjoint filters, until overlap semantics are defined.

        Parameters:
            C: Policy type with an accessor matching the filter.
            filter: Explicit read-only eligibility and access declaration.

        Args:
            classifier: Policy and configuration transferred into the world.

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
        """Explicitly classifies and orders eligible host archetypes by key.

        Dirty identities are classified once using their final values. Registration
        and structural changes request a full rebuild; clean calls do no work.
        No registered policy is an unlocked no-op. Queries and selections must
        be released first. Classifier errors leave all archetypes unchanged;
        movement follows the typed permutation guarantees in decision 0009.
        Component references must not survive maintenance.

        Raises:
            LarecsError: If storage is locked or classification fails.
        """
        self.storage._assert_unlocked()
        if self._spatial_classifier:
            self._spatial_maintenance.value()(
                self.storage, self._spatial_classifier.value()
            )
