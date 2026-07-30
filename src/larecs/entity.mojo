from std.bit import bit_reverse
from std.hashlib import Hasher

from tracy import Zone

from .types import EntityId
from .archetype import Archetype, EntityAccessor

# # Reflection type of an [Entity].
# var entityType = reflect.TypeOf(Entity{})

# # Size of an [Entity] in memory, in bytes.
# var entitySize uint32 = uint32(entityType.Size())

# # Size of an [entityIndex] in memory.
# var entityIndexSize uint32 = uint32(reflect.TypeOf(entityIndex{}).Size())


struct Entity(
    Boolable,
    Equatable,
    Hashable,
    ImplicitlyCopyable,
    KeyElement,
    TrivialRegisterPassable,
    Writable,
):
    """Entity identifier.
    Holds an entity ID and it's generation for recycling.

    Entities are only created via the [..world.World], using [..storage.Storage.add_entity].

    ⚠️ Important:
    Entities are intended to be stored and passed around via copy, not via pointers!
    The zero value should be used to indicate "nil", and can be checked with [.Entity.is_zero].
    """

    var _id: EntityId
    """Entity ID"""
    var _generation: UInt32
    """Entity generation"""

    @doc_hidden
    @always_inline
    def __init__(out self, id: EntityId = 0, generation: UInt32 = 0):
        """Initializes an entity from an ID and generation.

        Args:
            id: The entity ID.
            generation: The entity generation.
        """
        with Zone(
            function_name="Entity.__init__(id: EntityId, generation: UInt32)"
        ):
            self._id = id
            self._generation = generation

    @implicit
    @always_inline
    def __init__(out self, accessor: EntityAccessor):
        """
        Initializes the entity from an [..archetype.EntityAccessor].

        Args:
            accessor: The entity accessor to initialize from.
        """
        with Zone(function_name="Entity.__init__(accessor: EntityAccessor)"):
            self = accessor.get_entity()

    @always_inline
    def __eq__(self, other: Entity) -> Bool:
        """
        Compares two entities for equality.

        Args:
            other: The other entity to compare to.
        """
        with Zone(function_name="Entity.__eq__(other: Entity)"):
            return (
                self._id == other._id and self._generation == other._generation
            )

    @always_inline
    def __ne__(self, other: Entity) -> Bool:
        """
        Compares two entities for inequality.

        Args:
            other: The other entity to compare to.
        """
        with Zone(function_name="Entity.__ne__(other: Entity)"):
            return not (self == other)

    @always_inline
    def __bool__(self) -> Bool:
        """
        Returns whether this entity is not the zero entity.
        """
        with Zone(function_name="Entity.__bool__()"):
            return self._id != 0

    @deprecated(use=write_to)
    @always_inline
    def __str__(self) -> String:
        """
        Returns a string representation of the entity.
        """
        with Zone(function_name="Entity.__str__()"):
            return (
                "Entity("
                + String(self._id)
                + ", "
                + String(self._generation)
                + ")"
            )

    @always_inline
    def __hash__[H: Hasher](self, mut hasher: H):
        """Returns a unique hash of the entity."""
        with Zone(function_name="Entity.__hash__[H: Hasher](mut hasher: H)"):
            hasher.update(self._id)
            hasher.update(self._generation)

    @always_inline
    def get_id(self) -> EntityId:
        """Returns the entity's ID."""
        with Zone(function_name="Entity.get_id()"):
            return self._id

    @always_inline
    def get_generation(self) -> UInt32:
        """Returns the entity's generation."""
        with Zone(function_name="Entity.get_generation()"):
            return self._generation

    @always_inline
    def is_zero(self) -> Bool:
        """Returns whether this entity is the reserved zero entity."""
        with Zone(function_name="Entity.is_zero()"):
            return self._id == 0


@fieldwise_init
struct EntityLocation(ImplicitlyCopyable, TrivialRegisterPassable):
    """Indicates where an entity is currently stored."""

    # Entity's current index in the archetype
    var entity_index: Int
    """Entity's current index in its archetype."""

    # Entity's current archetype
    var archetype_index: Int
    """Index of the archetype currently storing the entity."""
