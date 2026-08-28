from tracy import Zone

from max.gpu.host import DeviceContext

from .component import (
    ComponentType,
)
from .host_storage import HostStorage
from .device_storage import DeviceStorage
from .resource import Resources


struct World[*component_types: ComponentType](Copyable, Sized):
    """
    World is the central type holding entity and component data, as well as resources.

    The World provides all the basic ECS functionality of Larecs through it's member [..host_storage.HostStorage storage].
    These include functions like [..host_storage.HostStorage.query], [..host_storage.HostStorage.add_entity], [..host_storage.HostStorage.add], [..host_storage.HostStorage.remove], [..host_storage.HostStorage.get] or [..host_storage.HostStorage.remove_entity].
    """

    comptime HostStorage = HostStorage[*Self.component_types]
    var storage: Self.HostStorage
    """[..host_storage.HostStorage Component Storage] associated with the world."""

    comptime DeviceStorage = DeviceStorage[*Self.component_types]
    var _device_storage: Optional[Self.DeviceStorage]
    """[..device_storage.DeviceStorage Component Storage] associated with the world."""

    var resources: Resources  # The resources of the world.
    """[..resource.Resources Resource Storage] associated with the world."""

    def __init__(out self):
        """
        Creates a new [.World].
        """
        with Zone(function_name="World.__init__()"):
            self.storage = Self.HostStorage()
            try:
                self._device_storage = Self.DeviceStorage(DeviceContext(), 0)
            except:
                self._device_storage = None
            self.resources = Resources()

    def __len__(self, out size: Int):
        """
        Returns the number of entities in the world.

        Note that this requires iterating over all archetypes and
        may be an expensive operation.
        """
        with Zone(function_name="World.__len__(out size: Int)"):
            size = 0
            for archetype in self.storage._archetypes:
                size += len(archetype)
