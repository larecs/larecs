from tracy import Zone

from .pool import EntityPool
from .entity import Entity, EntityLocation
from .archetype import (
    Archetype as _Archetype,
    MutableEntityAccessor,
)
from .component import (
    ComponentManager,
    ComponentType,
    constrain_components_unique,
)
from .storage import Storage
from .static_optional import StaticOptional
from .resource import Resources
from .error import (
    LarecsError,
    UnknownError,
    ComponentError,
    WorldError,
    EntityError,
)


struct World[*component_types: ComponentType](Copyable, Sized):
    """
    World is the central type holding entity and component data, as well as resources.

    The World provides all the basic ECS functionality of Larecs through it's member [..storage.Storage storage].
    These include functions like [..storage.Storage.query], [..storage.Storage.add_entity], [..storage.Storage.add], [..storage.Storage.remove], [..storage.Storage.get] or [..storage.Storage.remove_entity].
    """

    comptime Storage = Storage[*Self.component_types]
    var storage: Self.Storage
    """[..storage.Storage Component Storage] associated with the world."""

    var resources: Resources  # The resources of the world.
    """[..resource.Resources Resource Storage] associated with the world."""

    def __init__(out self):
        """
        Creates a new [.World].
        """
        with Zone(function_name="World.__init__()"):
            self.storage = Self.Storage()
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
