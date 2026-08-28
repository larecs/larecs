from tracy import Zone

from .bitmask import BitMask
from .component import Components, ComponentType, ComponentManager
from .static_optional import StaticOptional


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

    def get_bitmask_filter[
        *ComponentTypes: ComponentType
    ](self) -> BitMaskFilter[len(Self._exclude) > 0]:
        comptime if len(Self._exclude) > 0:
            return BitMaskFilter[len(Self._exclude) > 0](
                include=self.get_include_mask[*ComponentTypes](),
                exclude=self.get_exclude_mask[*ComponentTypes](),
            )
        else:
            return BitMaskFilter[len(Self._exclude) > 0](
                include=self.get_include_mask[*ComponentTypes](),
            )


struct BitMaskFilter[
    is_excluding: Bool = False,
](ImplicitlyCopyable):
    """
    A filter that stores which components are included and excluded with BitMask.

    Parameters:
        is_excluding: Whether the BitMaskFilter has excluded components.
    """

    var include_mask: BitMask
    """Component mask that matching archetypes must contain."""
    var exclude_mask: StaticOptional[BitMask, Self.is_excluding]
    """Optional component mask that matching archetypes must not contain."""

    comptime ExcludingBitMaskFilter = BitMaskFilter[is_excluding=True]
    """Query information type with an active exclusion mask."""

    def __init__(
        out self,
        include: BitMask,
        exclude: StaticOptional[BitMask, Self.is_excluding] = None,
    ):
        """
        Constructs a BitMaskFilter with the given include and exclude masks.

        Args:
            include: The mask of the components to include.
            exclude: The optional mask of the components to exclude.
        """
        with Zone(
            function_name=(
                "BitMaskFilter.__init__(include: BitMask, exclude:"
                " StaticOptional[BitMask, Self.is_excluding])"
            )
        ):
            self.include_mask = include

            comptime if Self.is_excluding:
                self.exclude_mask = exclude.copy()
            else:
                self.exclude_mask = None

    def __init__(out self, *, copy: Self):
        """
        Copy constructor.

        Args:
            copy: The query to copy.
        """
        with Zone(function_name="BitMaskFilter.__init__(copy: Self)"):
            self.include_mask = copy.include_mask
            self.exclude_mask = copy.exclude_mask.copy()

    @always_inline
    def exclude(
        deinit self,
        var mask: BitMask,
        out filter: Self.ExcludingBitMaskFilter,
    ):
        """
        Adds excluded components to the filter.

        Args:
            exclude_mask: The component mask to exclude.

        Returns:
            BitMaskFilter with an active exclusion mask.
        """
        with Zone(
            function_name=(
                "BitMaskFilter.exclude(var mask: BitMask, out filter:"
                " Self.ExcludingBitMaskFilter)"
            )
        ):
            comptime if Self.is_excluding:
                self.exclude_mask[] |= mask^
                filter = Self.ExcludingBitMaskFilter(
                    self.include_mask^, self.exclude_mask[]
                )
            else:
                filter = Self.ExcludingBitMaskFilter(self.include_mask^, mask^)

    @always_inline
    def exclusive(deinit self, out filter: Self.ExcludingBitMaskFilter):
        """
        Makes the query information match exactly the included components.

        Returns:
            BitMaskFilter with an exclusion mask for all non-included components.
        """
        with Zone(
            function_name=(
                "BitMaskFilter.exclusive(out filter:"
                " Self.ExcludingBitMaskFilter)"
            )
        ):
            filter = Self.ExcludingBitMaskFilter(
                self.include_mask^, ~self.include_mask
            )

    def matches(self, archetype_mask: BitMask, out is_valid: Bool):
        """
        Checks whether the given archetype mask matches the filter.

        Args:
            archetype_mask: The mask of the archetype to check.

        Returns:
            Whether the archetype matches the filter.
        """
        with Zone(
            function_name=(
                "BitMaskFilter.matches(archetype_mask: BitMask, out is_valid:"
                " Bool)"
            )
        ):
            is_valid = archetype_mask.contains(self.include_mask)

            comptime if Self.is_excluding:
                is_valid &= not archetype_mask.contains_any(self.exclude_mask[])
