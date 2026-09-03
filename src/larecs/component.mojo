"""Component type registration and validation.

Provides `ComponentManager`, which assigns compile-time IDs to component
types and offers helpers for checking their validity.
"""

from std.collections.check_bounds import check_bounds
from std.sys import size_of

from std.collections import Set

from tracy import Zone

from .bitmask import BitMask
from .types import ComponentId


comptime ComponentType = Copyable & Deinitable
"""The trait that components must conform to."""


@fieldwise_init
struct Components[*ComponentTypes: ComponentType](Sized):
    """A compile-time list of component types.

    Parameters:
        ComponentTypes: The listed component types.
    """

    def __len__(self) -> Int:
        """Returns the number of component types included by the filter.

        Returns:
            The number of component types.
        """
        with Zone(function_name="Components.__len__()"):
            return len(self.ComponentTypes)


@always_inline
def constrain_components_unique[*Ts: ComponentType]() -> Bool:
    """Checks whether all component types are unique.

    Parameters:
        Ts: The component types to compare.

    Returns:
        True when no component type appears more than once.
    """
    with Zone(
        function_name=(
            "component.constrain_components_unique[*Ts: ComponentType]()"
        )
    ):
        var set = Set[String]()
        comptime for i in range(len(Ts)):
            _ = set.insert(reflect[Ts[i]].name())
        return len(set) == len(Ts)


def constrain_valid_components[*Ts: ComponentType]() -> Bool:
    """
    Checks if the provided components are valid.

    Parameters:
        Ts: The components to check.

    Returns:
        True when there is at least one component type and all are unique.
    """
    with Zone(
        function_name=(
            "component.constrain_valid_components[*Ts: ComponentType]()"
        )
    ):
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

    comptime _component_size = Self._calc_component_sizes()
    """A mapping from component ID to their size."""

    @staticmethod
    @always_inline
    def _create_registry(out dict: Dict[String, ComponentId]):
        """
        Create a registry mapping component type names to their IDs.

        Returns:
            A dictionary mapping component type names to their IDs.
        """
        with Zone(
            function_name=(
                "ComponentManager._create_registry(out dict:"
                " Dict[String, ComponentId])"
            )
        ):
            comptime assert Self.component_count <= Self.max_size, (
                "Too many component types. See `BitMask.total_bits` for the"
                " maximum size allowed."
            )

            dict = {}
            comptime for i in range(len(Self.ComponentTypes)):
                comptime T = Self.ComponentTypes[i]
                dict[reflect[T].name()] = ComponentId(i)

    @staticmethod
    @always_inline
    def _calc_component_sizes(out sizes: Array[Int, Self.component_count]):
        """Calculate the size of each component type."""
        with Zone(
            function_name=(
                "ComponentManager._calc_component_sizes(out sizes:"
                " Array[Int, Self.component_count])"
            )
        ):
            sizes = Array[Int, Self.component_count](fill=0)
            comptime for i in range(len(Self.ComponentTypes)):
                comptime T = Self.ComponentTypes[i]
                sizes[i] = size_of[T]()

    @staticmethod
    @always_inline
    def get_size(component_id: ComponentId) -> Int:
        """Get the size of a component type.

        Args:
            component_id: The ID of the component type.

        Returns:
            The size of the component type, in bytes.
        """
        with Zone(
            function_name="ComponentManager.get_size(component_id: ComponentId)"
        ):
            return materialize[Self._component_size]()[component_id]

    @staticmethod
    @always_inline
    def contains_components[*Ts: ComponentType]() -> Bool:
        """Checks whether all component types are registered in this manager.

        Parameters:
            Ts: The component types to check.

        Returns:
            True if all component types are registered, False otherwise.
        """
        with Zone(
            function_name=(
                "ComponentManager.contains_components[*Ts: ComponentType]()"
            )
        ):
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
        with Zone(
            function_name=(
                "ComponentManager.assert_valid_components[*Ts: ComponentType]()"
            )
        ):
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
        with Zone(function_name="ComponentManager.get_id[T: ComponentType]()"):
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
        with Zone(
            function_name=(
                "ComponentManager.get_id_arr[*Ts: ComponentType](out ids:"
                " Array[ComponentId, len(Ts)])"
            )
        ):
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
        with Zone(
            function_name="ComponentManager.write_to(mut writer: Some[Writer])"
        ):
            writer.write("ComponentManager[")
            comptime if len(Self.ComponentTypes) > 0:
                writer.write(self.get_type_name(0))
            comptime for i in range(1, len(Self.ComponentTypes)):
                writer.write(", ")
                writer.write(self.get_type_name(i))
            writer.write("]")

    @staticmethod
    def get_type_name(id: ComponentId) -> StaticString:
        """Get the name of a component type.

        Args:
            id: The ID of the component type.

        Returns:
            The name of the component type, or `"<UNKNOWN_COMPONENT>"`
            if no component type has this ID.
        """
        with Zone(
            function_name="ComponentManager.get_type_name(id: ComponentId)"
        ):
            comptime for i in range(len(Self.ComponentTypes)):
                if id == i:
                    return reflect[Self.ComponentTypes[i]].name()

            return "<UNKNOWN_COMPONENT>"
