from tracy import Zone

from .bitmask import BitMask
from .component import Components, ComponentType, ComponentManager


@fieldwise_init
struct Filter[
    _include: Components = Components[](), _exclude: Components = Components[]()
](Sized):
    comptime include[*ComponentTypes: ComponentType] = Filter[
        Components[
            *TypeList._concat[
                Self._include.ComponentTypes.values, ComponentTypes.values
            ]()
        ](),
        Self._exclude,
    ]
    comptime exclude[*ComponentTypes: ComponentType] = Filter[
        Self._include,
        Components[
            *TypeList._concat[
                Self._exclude.ComponentTypes.values, ComponentTypes.values
            ]()
        ](),
    ]

    def __len__(self) -> Int:
        """Returns the number of components included by the filter."""
        comptime include_length = len(self._include)
        return include_length

    def includes[T: ComponentType](self) -> Int:
        """Returns whether a filter includes component ``T``.

        Parameters:
            T: The component type to search for.

        Returns:
            The component index when ``T`` is included; otherwise ``-1``.
        """
        comptime for i in range(len(Self._include)):
            comptime if Self._include.ComponentTypes[i] == T:
                return i
        return -1

    def excludes[
        T: ComponentType,
    ](self) -> Int:
        """Returns whether a filter excludes component ``T``.

        Parameters:
            T: The component type to search for.

        Returns:
            The component index when ``T`` is excluded; otherwise ``-1``.
        """
        comptime for i in range(len(Self._exclude)):
            comptime if Self._exclude.ComponentTypes[i] == T:
                return i
        return -1

    def get_include_mask[*ComponentTypes: ComponentType](self) -> BitMask:
        comptime component_manager = ComponentManager[*ComponentTypes]
        return BitMask(
            component_manager.get_id_arr[*Self._include.ComponentTypes]()
        )

    def get_exclude_mask[*ComponentTypes: ComponentType](self) -> BitMask:
        comptime component_manager = ComponentManager[*ComponentTypes]
        return BitMask(
            component_manager.get_id_arr[*Self._exclude.ComponentTypes]()
        )
