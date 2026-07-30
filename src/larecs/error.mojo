from std.builtin.globals import global_constant
from std.utils import Variant

from .bitmask import BitMask
from .entity import Entity


comptime LarecsError = Variant[
    UnknownError,
    WorldError,
    EntityError,
    ComponentError,
]
"""Typed errors raised by public operations.

These indicate an error in the usage of Larecs.
"""


@fieldwise_init
struct UnknownError(Movable, Writable):
    """Represents an unknown error."""

    def write_to(self, mut writer: Some[Writer]):
        """Writes the error to a writer.

        Args:
            writer: The destination writer.
        """
        writer.write("LarecsError: Unknown error.")


struct WorldError(Equatable, ImplicitlyCopyable, Writable):
    """
    Errors that have some information about the world.
    """

    var _variant: Int
    """Numeric discriminator for the error variant."""

    comptime world_is_locked = WorldError(variant=1)
    """Error raised when the world is locked."""
    comptime out_of_locks = WorldError(variant=2)
    """Error raised when the world cannot allocate another lock."""

    @always_inline
    def __init__(out self, variant: Int = 0):
        assert variant < 3, "Invalid variant for WorldError"
        self._variant = variant

    @always_inline
    def msg(self) -> StaticString:
        """Returns the errors message.

        Returns:
            The human-readable message for the variant.
        """
        comptime WORLD_ERROR_VARIANT_MESSAGES: InlineArray[StaticString, 3] = [
            "Unknown error.",
            "Attempt to modify a locked world.",
            (
                "The world cannot allocate another lock. This is likely due to"
                " having too many queries open."
            ),
        ]

        ref global_variant_messages = global_constant[
            WORLD_ERROR_VARIANT_MESSAGES
        ]()
        return global_variant_messages[self._variant]

    def write_to(self, mut writer: Some[Writer]):
        """Writes the [.WorldError] to a writer.

        Args:
            writer: The destination writer.
        """
        writer.write("LarecsError: ")
        writer.write(self.msg())


struct EntityError(Equatable, ImplicitlyCopyable, Writable):
    """
    Errors that have some information about an entity.
    """

    var _variant: Int
    """Numeric discriminator for the error variant."""

    comptime non_existent_entity = EntityError(variant=1)
    """Error raised when an entity does not exist."""

    comptime MAX_ENTITY_COUNT = 10
    """The maximum number of entities that can be involved in an error."""

    var entities: InlineArray[Entity, Self.MAX_ENTITY_COUNT]
    """The entities involved in the error."""

    @always_inline
    def __init__[](out self, variant: Int = 0):
        assert variant < 2, "Invalid variant for EntityError"

        self._variant = variant
        self.entities = InlineArray[Entity, Self.MAX_ENTITY_COUNT](
            fill=Entity()  # fill with zero Entity
        )

    @always_inline
    def with_entities[
        entity_count: Int
    ](
        deinit self,
        entities: InlineArray[Entity, entity_count],
        out next_self: Self,
    ):
        comptime assert (
            entity_count <= Self.MAX_ENTITY_COUNT
        ), "Entity count exceeds maximum inline array size"
        next_self = self^
        for idx in range(entity_count):
            next_self.entities[idx] = entities[idx]

    @always_inline
    def with_entities(
        deinit self,
        var *entities: Entity,
        out next_self: Self,
    ):
        assert (
            len(entities) <= Self.MAX_ENTITY_COUNT
        ), "Entity count exceeds maximum inline array size"
        next_self = self^
        for idx in range(len(entities)):
            next_self.entities[idx] = entities[idx]

    @always_inline
    def msg(self) -> StaticString:
        """Returns the errors message.

        Returns:
            The human-readable message for the variant.
        """
        comptime ENTITY_ERROR_VARIANT_MESSAGES: InlineArray[StaticString, 2] = [
            "Unknown error.",
            "The considered entity does not exist anymore:",
        ]

        ref global_variant_messages = global_constant[
            ENTITY_ERROR_VARIANT_MESSAGES
        ]()
        return global_variant_messages[self._variant]

    def write_to(self, mut writer: Some[Writer]):
        """Writes the [.EntityError] to a writer.

        Args:
            writer: The destination writer.
        """

        writer.write("LarecsError: ")
        writer.write(self.msg())
        writer.write(" (")

        var first_iteration = True
        for entity in self.entities:
            if entity.is_zero():
                continue
            if not first_iteration:
                writer.write(", ")
            writer.write(t"{entity}")
            first_iteration = False

        writer.write(")")


struct ComponentError(Equatable, ImplicitlyCopyable, Writable):
    """
    Errors that have some information about one or more components.
    """

    var _variant: Int
    """Numeric discriminator for the error variant."""

    comptime missing_components_on_remove = ComponentError(variant=1)
    """Error raised when components are missing on removal."""
    comptime existing_components_on_add = ComponentError(variant=2)
    """Error raised when components are missing on addition."""
    comptime missing_components_on_assert = ComponentError(variant=3)
    """Error raised when components are missing on assertion."""

    comptime missing_components_on_remove_query = ComponentError(variant=4)
    """Error raised when components are missing on removal in a query."""
    comptime existing_components_on_add_query = ComponentError(variant=5)
    """Error raised when components are missing on addition in a query."""

    var components: BitMask
    """The bitmask where all bits of the corresponding components are set."""

    @always_inline
    def __init__(
        out self,
        variant: Int = 0,
    ):
        assert variant < 6, "Invalid variant for ComponentError"
        self._variant = variant
        self.components = BitMask(0)

    @always_inline
    def with_components(deinit self, components: BitMask, out next_self: Self):
        next_self = self^
        next_self.components = components

    @always_inline
    def msg(self) -> StaticString:
        """Returns the errors message.

        Returns:
            The human-readable message for the variant.
        """
        comptime COMPONENT_ERROR_VARIANT_MESSAGES: InlineArray[
            StaticString, 6
        ] = [
            "Unknown error.",
            "Entity does not have all the components to remove:",
            "Entity already has components that are being added:",
            "Entity misses components required by assertion:",
            (
                "Query matches entities that do not have all the components to"
                " remove. Use `Query[Component, ...]()` to include those"
                " components:"
            ),
            (
                "Query matches entities that already have some of the"
                " components to add. Use `Query.without[Component, ...]()` to"
                " exclude those components:"
            ),
        ]

        ref global_variant_messages = global_constant[
            COMPONENT_ERROR_VARIANT_MESSAGES
        ]()
        return global_variant_messages[self._variant]

    def write_to(self, mut writer: Some[Writer]):
        """Writes the [.ComponentError] to a writer.

        Args:
            writer: The destination writer.
        """

        writer.write("LarecsError: ")
        writer.write(self.msg())
        writer.write(" (")

        var first_iteration = True
        for component_id in self.components.get_indices():
            if not first_iteration:
                writer.write(", ")
            writer.write(t"{component_id}")
            first_iteration = False

        writer.write(")")
