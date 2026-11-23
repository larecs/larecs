"""Compile-time component inclusion/exclusion specs for queries.

Provides `Filter`, built up via `include`/`exclude`, and `BitMaskFilter`,
its runtime BitMask-based counterpart used to match archetypes.
"""

from tracy import Zone

from .bitmask import BitMask
from .component import Components, ComponentType, ComponentManager
from .static_optional import StaticOptional


@fieldwise_init
struct Filter[
    _include: Components = Components[](),
    _exclude: Components = Components[](),
    _is_exclusive: Bool = False,
    _read: Components = Components[](),
    _written: Components = Components[](),
](Sized):
    """Compile-time component inclusion and exclusion spec used to build queries.

    Every included component is tracked separately as readable (`_read`)
    and/or writable (`_written`). `include` -- the default, and the only
    mode that matters for the host query API, where this distinction is not
    used -- marks a component both readable and writable, matching this
    type's behavior before `_read`/`_written` existed. `read` and `write`
    mark a component for one direction only: a kernel running on the device then only
    pays for the transfer direction it actually needs (see `SystemContext.run`),
    and `EntityAccessor.get`/`set` enforce the declared mode at compile
    time, not just by convention -- see `read` and `write` below.

    Build a filter by chaining `include`, `read`, `write`, `exclude`, and
    `exclusive`, then call the result, as in
    `Filter().include[Position].read[Velocity]()`. Each step names a new
    `Filter` type; the trailing `()` constructs the filter value that queries
    and kernels take. Without it, the compiler reports
    `failed to infer parameter '_include'`. Calling every step, as in
    `Filter().include[Position]().exclude[Velocity]()`, builds the same filter.

    A named filter can be extended, which lets several systems share a base
    filter:

    ```mojo {doctest="filter_composition" global=true hide=true}
    from larecs import Filter, World
    from std.testing import assert_equal
    ```

    ```mojo {doctest="filter_composition" global=true}
    @fieldwise_init
    struct Position(Copyable, Movable):
        var x: Float64
        var y: Float64

    @fieldwise_init
    struct Velocity(Copyable, Movable):
        var dx: Float64
        var dy: Float64

    @fieldwise_init
    struct Frozen(Copyable, Movable):
        pass

    comptime moving = Filter().include[Position].read[Velocity]()
    comptime moving_unfrozen = moving.exclude[Frozen]()

    def main() raises:
        var world = World[Position, Velocity, Frozen]()
        _ = world.storage.add_entity(Position(0, 0), Velocity(1, 0))
        _ = world.storage.add_entity(Position(0, 0), Velocity(1, 0), Frozen())
        assert_equal(len(world.storage.query[moving]()), 2)
        assert_equal(len(world.storage.query[moving_unfrozen]()), 1)
    ```

    Parameters:
        _include: The component types that must be present.
        _exclude: The component types that must be absent.
        _is_exclusive: Whether only the included components may be present.
        _read: The included component types accessible for reading.
        _written: The included component types accessible for writing.
    """

    comptime include[*ComponentTypes: ComponentType] = Filter[
        Components[
            *TypeList._concat[
                Self._include.ComponentTypes.values, ComponentTypes.values
            ]()
        ](),
        Self._exclude,
        Self._is_exclusive,
        Components[
            *TypeList._concat[
                Self._read.ComponentTypes.values, ComponentTypes.values
            ]()
        ](),
        Components[
            *TypeList._concat[
                Self._written.ComponentTypes.values, ComponentTypes.values
            ]()
        ](),
    ]
    """Returns a Filter also including the given component types for both reading and writing.

    Parameters:
        ComponentTypes: The component types to include.
    """
    comptime read[*ComponentTypes: ComponentType] = Filter[
        Components[
            *TypeList._concat[
                Self._include.ComponentTypes.values, ComponentTypes.values
            ]()
        ](),
        Self._exclude,
        Self._is_exclusive,
        Components[
            *TypeList._concat[
                Self._read.ComponentTypes.values, ComponentTypes.values
            ]()
        ](),
        Self._written,
    ]
    """Returns a Filter also including the given component types, accessible only for reading.

    `EntityAccessor.get` returns an immutable reference for these
    components; `EntityAccessor.set` is a compile error. `SystemContext.run`'s
    device path uploads these components before the kernel runs but does not
    download them afterward, since a read-only kernel cannot have changed
    them.

    Parameters:
        ComponentTypes: The component types to include for reading only.
    """
    comptime write[*ComponentTypes: ComponentType] = Filter[
        Components[
            *TypeList._concat[
                Self._include.ComponentTypes.values, ComponentTypes.values
            ]()
        ](),
        Self._exclude,
        Self._is_exclusive,
        Self._read,
        Components[
            *TypeList._concat[
                Self._written.ComponentTypes.values, ComponentTypes.values
            ]()
        ](),
    ]
    """Returns a Filter also including the given component types, accessible only for writing.

    `EntityAccessor.set` overwrites these components; `EntityAccessor.get`
    is a compile error, since a write-only component's prior value is
    never uploaded to the kernel. `SystemContext.run`'s device path downloads
    these components after the kernel runs but does not upload them
    beforehand, since a write-only kernel never reads their prior value.

    Parameters:
        ComponentTypes: The component types to include for writing only.
    """
    comptime exclude[*ComponentTypes: ComponentType] = Filter[
        Self._include,
        Components[
            *TypeList._concat[
                Self._exclude.ComponentTypes.values, ComponentTypes.values
            ]()
        ](),
        Self._is_exclusive,
        Self._read,
        Self._written,
    ]
    """Returns a Filter also excluding the given component types.

    Parameters:
        ComponentTypes: The component types to exclude.
    """

    comptime exclusive = Filter[
        Self._include,
        Components[](),
        True,
        Self._read,
        Self._written,
    ]
    """Returns a Filter that matches only entities with exactly the included components.

    `exclusive` discards the component types excluded so far, because an
    exclusive filter already rejects every component it does not include.
    `Filter().include[B]().exclude[A]().exclusive()` therefore holds no
    excluded types, while `Filter().include[B]().exclusive().exclude[A]()`
    holds `A`; both match only entities whose components are exactly `B`.
    """

    def __len__(self) -> Int:
        """Returns the number of components included by the filter.

        Returns:
            The number of included components.
        """
        with Zone(function_name="Filter.__len__()"):
            comptime include_length = len(self._include)
            return include_length

    def includes[T: ComponentType](self) -> Int:
        """Returns the index of component ``T`` among the included types.

        Compare the result with `-1` to test for inclusion. Do not use it as a
        `Bool`: index `0` is falsy, and the absent result `-1` is truthy.

        Parameters:
            T: The component type to search for.

        Returns:
            The position of ``T`` in the included types, or ``-1`` when the
            filter does not include ``T``.
        """
        with Zone(function_name="Filter.includes[T: ComponentType]()"):
            comptime for i in range(len(Self._include)):
                comptime if Self._include.ComponentTypes[i] == T:
                    return i
            return -1

    def excludes[
        T: ComponentType,
    ](self) -> Int:
        """Returns the index of component ``T`` among the excluded types.

        Compare the result with `-1` to test for exclusion. Do not use it as a
        `Bool`: index `0` is falsy, and the absent result `-1` is truthy.

        Parameters:
            T: The component type to search for.

        Returns:
            The position of ``T`` in the excluded types, or ``-1`` when the
            filter does not exclude ``T``.
        """
        with Zone(function_name="Filter.excludes[T: ComponentType]()"):
            comptime for i in range(len(Self._exclude)):
                comptime if Self._exclude.ComponentTypes[i] == T:
                    return i
            return -1

    comptime reads[T: ComponentType] = Self._read.ComponentTypes.contains[T]()
    """Returns whether this filter allows reading component ``T``.

    Parameters:
        T: The component type to check.

    Returns:
        True when ``T`` is accessible for reading, via `read` or
        `include`.
    """

    comptime writes[T: ComponentType] = Self._written.ComponentTypes.contains[
        T
    ]()
    """Returns whether this filter allows writing component ``T``.

    Parameters:
        T: The component type to check.

    Returns:
        True when ``T`` is accessible for writing, via `write` or
        `include`.
    """

    def get_include_mask[*ComponentTypes: ComponentType](self) -> BitMask:
        """Returns the bitmask of the components this filter includes.

        Parameters:
            ComponentTypes: The component types to query against.

        Returns:
            The mask of the included components.
        """
        with Zone(
            function_name=(
                "Filter.get_include_mask[*ComponentTypes:"
                " ComponentType]() -> BitMask"
            )
        ):
            comptime component_manager = ComponentManager[*ComponentTypes]

            return BitMask(
                component_manager.get_id_arr[*Self._include.ComponentTypes]()
            )

    def get_exclude_mask[*ComponentTypes: ComponentType](self) -> BitMask:
        """Returns the bitmask of the components this filter excludes.

        Parameters:
            ComponentTypes: The component types to query against.

        Returns:
            The mask of the excluded components, or the inverse of the
            include mask when the filter is exclusive.
        """
        with Zone(
            function_name=(
                "Filter.get_exclude_mask[*ComponentTypes:"
                " ComponentType]() -> BitMask"
            )
        ):
            comptime component_manager = ComponentManager[*ComponentTypes]

            comptime if Self._is_exclusive:
                return ~BitMask(
                    component_manager.get_id_arr[
                        *Self._include.ComponentTypes
                    ]()
                )
            else:
                return BitMask(
                    component_manager.get_id_arr[
                        *Self._exclude.ComponentTypes
                    ]()
                )

    def get_bitmask_filter[
        *ComponentTypes: ComponentType
    ](self) -> BitMaskFilter[len(Self._exclude) > 0 or Self._is_exclusive]:
        """Returns a BitMaskFilter for this filter.

        Parameters:
            ComponentTypes: The component types to query against.

        Returns:
            A BitMaskFilter with the appropriate include and exclude masks.
        """
        with Zone(
            function_name=(
                "Filter.get_bitmask_filter[*ComponentTypes: ComponentType]()"
                " -> BitMaskFilter[len(Self._exclude) > 0 or"
                " Self._is_exclusive]"
            )
        ):
            comptime if len(Self._exclude) > 0 or Self._is_exclusive:
                return rebind[
                    BitMaskFilter[len(Self._exclude) > 0 or Self._is_exclusive]
                ](
                    BitMaskFilter[True](
                        include=self.get_include_mask[*ComponentTypes](),
                        exclude=self.get_exclude_mask[*ComponentTypes](),
                    )
                )
            else:
                return rebind[
                    BitMaskFilter[len(Self._exclude) > 0 or Self._is_exclusive]
                ](
                    BitMaskFilter[False](
                        include=self.get_include_mask[*ComponentTypes](),
                    )
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
        with Zone(function_name="BitMaskFilter.__init__(*, copy: Self)"):
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
            mask: The component mask to exclude.

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
