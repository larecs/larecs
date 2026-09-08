"""Shared integer type aliases used across the ECS."""

# Eid is the entity identifier/index type.
comptime EntityId = Int
"""The integer type used for entity identifiers."""

# ComponentId is the component identifier type.
comptime ComponentId = Int
"""The integer type used for compact component identifiers."""


# # ResID is the resource identifier type.
# type ResID = uint8

# # Component is a component ID/pointer pair.
# #
# # It is a helper for [World.Assign], [World.NewEntityWith] and [NewBuilderWith].
# # It is not related to how components are implemented in Arche.
# type Component struct:
#     ID   ID          # Component ID.
#     Comp interface{} # The component, as a pointer to a struct.

# # componentType is a component ID with a data type
# type componentType struct:
#     ID
#     Type reflect.Type
