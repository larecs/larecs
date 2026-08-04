from std.collections.check_bounds import check_bounds
from std.sys import size_of

from std.collections import Set

from tracy import Zone

from .bitmask import BitMask
from .types import ComponentId


comptime ComponentType = Copyable & Deinitable
"""The trait that components must conform to."""


@always_inline
def constrain_components_unique[*Ts: ComponentType]() -> Bool:
    """Checks whether all component types are unique.

    Parameters:
        Ts: The component types to compare.

    Returns:
        True when no component type appears more than once.
    """
    set = Set[String]()
    comptime for i in range(len(Ts)):
        _ = set.insert(reflect[Ts[i]].name())
    return len(set) == len(Ts)


def constrain_valid_components[*Ts: ComponentType]() -> Bool:
    """
    Checks if the provided components are valid.

    Parameters:
        Ts: The components to check.
    """
    return len(Ts) > 0 and constrain_components_unique[*Ts]()


struct ComponentManager[
    *ComponentTypes: ComponentType,
](TrivialRegisterPassable, Writable):
    """ComponentManager is a manager for ECS components.

    It is used to assign IDs to types and to create
    references for passing them around.

    Parameters:
        ComponentTypes: The component types that the manager should handle.
    """

    comptime max_size = BitMask.total_bits
    """The maximal number of component types."""

    comptime component_count = len(Self.ComponentTypes)
    """The number of component types handled by this ComponentManager."""

    comptime _registry = Self._create_registry()
    """The registry mapping component type names to their IDs."""

    @staticmethod
    @always_inline
    def _create_registry(out dict: Dict[String, ComponentId]):
        """
        Create a registry mapping component type names to their IDs.

        Returns:
            A dictionary mapping component type names to their IDs.
        """
        comptime assert Self.component_count <= Self.max_size, (
            "Too many component types. See `BitMask.total_bits` for the maximum"
            " size allowed."
        )

        dict = {}
        comptime for i in range(len(Self.ComponentTypes)):
            comptime T = Self.ComponentTypes[i]
            dict[reflect[T].name()] = ComponentId(i)

    @staticmethod
    @always_inline
    def contains_components[*Ts: ComponentType]() -> Bool:
        """Checks whether all component types are registered in this manager.

        Parameters:
            Ts: The component types to check.

        Returns:
            True if all component types are registered, False otherwise.
        """
        comptime for i in range(len(Ts)):
            comptime T = Ts[i]
            comptime if reflect[T].name() not in Self._registry:
                return False
        return True

    @staticmethod
    @always_inline
    def assert_valid_components[*Ts: ComponentType]():
        """Assert that all component types are valid.

        Parameters:
            Ts: The component types to check.
        """
        comptime assert Self.contains_components[
            *Ts
        ](), "Not all component types are valid for this component manager."

    @staticmethod
    @always_inline
    def get_id[T: ComponentType]() -> ComponentId:
        """Get the ID of a component type.

        Parameters:
            T: The component type. Constraints: Must be in the list of component types.

        Returns:
            The ID of the component type.
        """
        comptime assert Self.contains_components[
            T
        ](), "Component type not in component manager"

        comptime id = Self._registry.get(reflect[T].name())
        return id.unsafe_value()

    @staticmethod
    @always_inline
    def get_id_arr[*Ts: ComponentType](out ids: Array[ComponentId, len(Ts)]):
        """Get the IDs of multiple component types.

        Parameters:
            Ts: The component types.

        Returns:
            An Array with the IDs of the component types.

        Constraints:
            The component types must be pair-wise different.
        """
        comptime assert constrain_components_unique[
            *Ts
        ](), "Duplicate component types in get_id_arr are not allowed."
        ids = Array[ComponentId, len(Ts)](uninitialized=True)

        comptime for i in range(len(Ts)):
            ids[i] = Self.get_id[Ts[i]]()

    def write_to(self, mut writer: Some[Writer]):
        """Writes the component manager to a writer.

        Args:
            writer: The writer to write to.
        """
        writer.write("ComponentManager[")
        comptime if len(Self.ComponentTypes) > 0:
            writer.write(reflect[Self.ComponentTypes[0]].name())
        comptime for i in range(1, len(Self.ComponentTypes)):
            writer.write(", ")
            writer.write(reflect[Self.ComponentTypes[i]].name())
        writer.write("]")
