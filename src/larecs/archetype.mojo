from std.sys.defines import is_defined
from std.reflection import reflect
from std.memory import (
    Layout,
    ThinAllocation,
    alloc,
    dealloc,
    unsafe_uninit_copy_n,
    unsafe_uninit_move_n,
    unsafe_destroy_n,
)
from std.bit import next_power_of_two

from tracy import Zone

from .entity import Entity
from .component import (
    ComponentType,
    constrain_components_unique,
    ComponentManager,
)
from .bitmask import BitMask
from .pool import EntityPool
from .types import ComponentId
from ._utils import (
    _assert_index_in_bounds,
    _assert_range_in_bounds,
    assert_unreachable,
)
from .error import LarecsError, ComponentError

comptime DEFAULT_CAPACITY = 32
"""Default capacity of an archetype."""

comptime MutArchetypeRowAccessor = ArchetypeRowAccessor[
    archetype_mutability=True, ...
]
"""An accessor with mutable references to an archetype row and its components."""


struct ArchetypeRowAccessor[
    archetype_mutability: Bool,
    //,
    archetype_origin: Origin[mut=archetype_mutability],
    *ComponentTypes: ComponentType,
](Movable):
    """Accessor for an Entity.

    Caution: use this only in the context it was created in.
    In particular, do not store it anywhere.

    Parameters:
        archetype_mutability: Whether the reference to the list is mutable.
        archetype_origin: The lifetime of the List.
        ComponentTypes: The types of the components.
    """

    comptime Archetype = Archetype[*Self.ComponentTypes]
    """The archetype of the entity."""

    var _archetype: Pointer[Self.Archetype, Self.archetype_origin]
    """Pointer to the archetype that owns this entity row."""
    var _index_in_archetype: Int
    """Index of the entity row within the archetype."""

    @doc_hidden
    def __init__(
        out self: ArchetypeRowAccessor[
            Self.archetype_origin, *Self.ComponentTypes
        ],
        ref[Self.archetype_origin] archetype: Self.Archetype,
        index_in_archetype: Int,
    ):
        """
        Args:
            archetype: The archetype of the entity.
            index_in_archetype: The index of the entity in the archetype.
        """
        with Zone(
            function_name=(
                "ArchetypeRowAccessor.__init__(ref archetype: Self.Archetype,"
                " index_in_archetype: Int)"
            )
        ):
            self._archetype = Pointer(to=archetype)
            self._index_in_archetype = index_in_archetype

    @always_inline
    def get_entity(self) -> Entity:
        """Returns the entity of the accessor.

        Returns:
            The entity of the accessor.
        """

        with Zone(function_name="ArchetypeRowAccessor.get_entity()"):
            return self._archetype[].get_entity(self._index_in_archetype)

    @__unsafe_nested_origins_read_only
    @always_inline
    def get[
        T: ComponentType
    ](ref self) raises LarecsError -> ref[self.archetype_origin] T:
        """Returns a reference to the given component of the Entity.

        Parameters:
            T: The type of the component.

        Raises:
            LarecsError: If the entity's archetype does not contain the component.

        Returns:
            A reference to the component of the entity.
        """

        with Zone(function_name="ArchetypeRowAccessor.get[T: ComponentType]()"):
            self._archetype[].assert_has_components[T]()

            return self._archetype[].get_component[T](
                self._index_in_archetype,
            )

    @always_inline
    def set[
        *Ts: ComponentType
    ](
        self, var *components: *Ts
    ) raises LarecsError where Self.archetype_origin.mut:
        """
        Overwrites components for an [..entity.Entity], using the given content.

        Parameters:
            Ts:        The types of the components.

        Args:
            components: The new components.

        Raises:
            LarecsError: If the entity's archetype does not contain one of the components.
        """
        with Zone(
            function_name=(
                "ArchetypeRowAccessor.set[*Ts: ComponentType](var *components:"
                " *Ts)"
            )
        ):
            comptime assert constrain_components_unique[
                *Ts
            ](), "Component types must be unique."

            ref archetype = self._archetype.unsafe_mut_cast[True]()[]
            archetype.set_components[*Ts](
                self._index_in_archetype, *components^
            )

    @always_inline
    def has[T: ComponentType](self) -> Bool:
        """
        Returns whether an [..entity.Entity] has a given component.

        Parameters:
            T: The type of the component.

        Returns:
            Whether the entity has the component.
        """
        with Zone(function_name="ArchetypeRowAccessor.has[T: ComponentType]()"):
            return self._archetype[].has_components[T]()


struct _ComponentColumn(Copyable, Deinitable, Movable):
    """Owns one type-erased component column allocation.

    The allocation is erased only while it is stored. Lifecycle operations keep
    the concrete component type through callbacks installed by the constructor.
    """

    comptime Data = Optional[ThinAllocation[Byte]]
    """Type-erased optional allocation used to store component data."""

    var _data: Self.Data
    """The allocation containing the column's component values."""
    var _destroy: def(
        var allocation: ThinAllocation[Byte], length: Int, capacity: Int
    ) thin
    """Callback that destroys initialized values and frees a column allocation."""
    var _copy: def(
        data: Self.Data, length: Int, capacity: Int
    ) thin -> Self.Data
    """Callback that copies initialized values into a new allocation."""
    var _resize: def(
        mut data: Self.Data,
        length: Int,
        old_capacity: Int,
        new_capacity: Int,
    ) thin -> Self.Data
    """Callback that moves values into an allocation with a new capacity."""
    var _swap_remove: def(
        mut data: Self.Data, length: Int, remove_idx: Int
    ) thin
    """Callback that removes and destroys one value from a column."""

    @staticmethod
    def _empty_destroy(
        var data: ThinAllocation[Byte], length: Int, capacity: Int
    ):
        """Frees an empty column allocation without destroying values."""
        dealloc(data^.unsafe_with_layout(Layout[Byte](count=capacity)))

    @staticmethod
    def _empty_copy(data: Self.Data, length: Int, capacity: Int) -> Self.Data:
        """Returns no allocation for an untyped empty column."""
        return None

    @staticmethod
    def _empty_resize(
        mut data: Self.Data,
        length: Int,
        old_capacity: Int,
        new_capacity: Int,
    ) -> Self.Data:
        """Leaves an untyped empty column without allocating storage."""
        return None

    @staticmethod
    def _empty_swap_remove(mut data: Self.Data, length: Int, remove_idx: Int):
        """Does nothing because an untyped empty column has no values."""
        pass

    def __init__(out self):
        """
        Initializes an empty _ComponentColumn.
        """
        self._data = None
        self._destroy = Self._empty_destroy
        self._copy = Self._empty_copy
        self._resize = Self._empty_resize
        self._swap_remove = Self._empty_swap_remove

    @staticmethod
    def _destroy_t[
        T: ComponentType
    ](var byte_thin: ThinAllocation[Byte], length: Int, capacity: Int):
        """Destroys initialized values of type `T` and frees their allocation.

        Parameters:
            T: The component type stored by this column.

        Args:
            byte_thin: The type-erased allocation containing the values.
            length: The number of initialized values.
            capacity: The allocation capacity.
        """
        var allocation = rebind_var[ThinAllocation[T]](
            byte_thin^
        ).unsafe_with_layout(Layout[T](count=capacity))
        unsafe_destroy_n(pointer=allocation.unsafe_ptr(), count=length)
        dealloc(allocation^)

    @staticmethod
    def _copy_t[
        T: ComponentType
    ](data: Self.Data, length: Int, capacity: Int) -> Self.Data:
        """Copies initialized values of type `T` into a new allocation.

        Parameters:
            T: The component type stored by this column.

        Args:
            data: The source allocation, if present.
            length: The number of values to copy.
            capacity: The capacity of the new allocation.

        Returns:
            A type-erased allocation containing the copied values, or `None`.
        """
        if data:
            var copy_allocation = alloc(Layout[T](count=capacity))
            unsafe_uninit_copy_n[overlapping=False](
                dest=copy_allocation.unsafe_ptr(),
                src=data.value().unsafe_ptr().unsafe_bitcast[T](),
                count=length,
            )
            return {
                rebind_var[ThinAllocation[Byte]](copy_allocation^.into_thin())
            }
        return None

    @staticmethod
    def _resize_t[
        T: ComponentType
    ](
        mut data: Self.Data,
        length: Int,
        old_capacity: Int,
        new_capacity: Int,
    ) -> Self.Data:
        """Moves values of type `T` into storage with a new capacity.

        Parameters:
            T: The component type stored by this column.

        Args:
            data: The existing allocation, if present.
            length: The number of initialized values.
            old_capacity: The capacity of the existing allocation.
            new_capacity: The capacity of the new allocation.

        Returns:
            A type-erased allocation with the moved values.
        """
        var new_allocation = alloc[T](Layout[T](count=new_capacity))
        if data:
            var old_data = data.take()
            unsafe_uninit_move_n[overlapping=False](
                dest=new_allocation.unsafe_ptr(),
                src=old_data.unsafe_ptr().unsafe_bitcast[T](),
                count=length,
            )
            dealloc(
                old_data
                ^.unsafe_with_layout(
                    Layout[T](count=old_capacity).as_byte_layout()
                )
            )
        return {rebind_var[ThinAllocation[Byte]](new_allocation^.into_thin())}

    @staticmethod
    def _swap_remove_t[
        T: ComponentType
    ](mut data: Self.Data, length: Int, remove_idx: Int):
        """Destroys one value of type `T` and fills its slot from the end.

        Parameters:
            T: The component type stored by this column.

        Args:
            data: The column allocation.
            length: The current number of values.
            remove_idx: The index of the value to remove.
        """
        var ptr = data.value().unsafe_ptr().unsafe_bitcast[T]()
        unsafe_destroy_n(ptr.unsafe_offset(remove_idx), count=1)
        if remove_idx != length - 1:
            unsafe_uninit_move_n[overlapping=False](
                dest=ptr.unsafe_offset(remove_idx).as_unsafe_any_origin(),
                src=ptr.unsafe_offset(length - 1),
                count=1,
            )

    @staticmethod
    def create[
        T: ComponentType
    ](out column: Self, *, preallocate: Bool, capacity: Int):
        """Creates a column whose callbacks operate on component type `T`.

        Parameters:
            T: The component type stored by this column.

        Args:
            preallocate: Whether to allocate storage immediately.
            capacity: The initial allocation capacity.
        """
        column = Self()
        column._destroy = Self._destroy_t[T]
        column._copy = Self._copy_t[T]
        column._resize = Self._resize_t[T]
        column._swap_remove = Self._swap_remove_t[T]
        var empty: Self.Data = None
        if preallocate:
            column._data^.deinit_assert_empty()
            column._data = Self._resize_t[T](empty, 0, 0, capacity)
        empty^.deinit_assert_empty()

    def __init__(out self, *, copy: Self):
        """Initializes an empty column with the source column's callbacks."""
        self._data = None
        self._destroy = copy._destroy
        self._copy = copy._copy
        self._resize = copy._resize
        self._swap_remove = copy._swap_remove

    def __deinit__(deinit self):
        """Asserts that the column allocation was explicitly destroyed."""
        self._data^.deinit_assert_empty()

    def copy_data_from(mut self, source: Self, length: Int, capacity: Int):
        """Copies initialized values from another column into this column.

        Args:
            source: The source column.
            length: The number of values to copy.
            capacity: The capacity of the copied allocation.
        """
        self._data^.deinit_assert_empty()
        self._data = self._copy(source._data, length, capacity)

    def resize(mut self, length: Int, old_capacity: Int, new_capacity: Int):
        """Resizes the column allocation while preserving initialized values.

        Args:
            length: The number of initialized values.
            old_capacity: The current allocation capacity.
            new_capacity: The requested allocation capacity.
        """
        var old_data = self._data^
        self._data = self._resize(old_data, length, old_capacity, new_capacity)
        old_data^.deinit_assert_empty()

    def swap_remove(mut self, length: Int, remove_idx: Int):
        """Removes a value by replacing it with the final value in the column.

        Args:
            length: The current number of values.
            remove_idx: The index of the value to remove.
        """
        self._swap_remove(self._data, length, remove_idx)

    def destroy(mut self, length: Int, capacity: Int):
        """Destroys initialized values and releases the column allocation.

        Args:
            length: The number of initialized values.
            capacity: The allocation capacity.
        """
        if self._data:
            self._destroy(self._data.take(), length, capacity)

    def get_ptr[
        T: ComponentType
    ](ref self) -> Pointer[T, UntrackedOrigin[mut=origin_of(self).mut]]:
        """Returns a typed pointer to the first value in the column.

        Parameters:
            T: The component type stored by this column.

        Returns:
            A pointer to the column's component values.
        """
        return (
            self._data.value()
            .unsafe_ptr()
            .unsafe_bitcast[T]()
            .unsafe_origin_cast[UntrackedOrigin[mut=origin_of(self).mut]]()
        )


struct _ComponentTable[*ComponentTypes: ComponentType](
    Copyable, Deinitable, Movable, Sized
):
    """
    Internal struct to store component data for an archetype.

    Optional[ThinAllocation] to the component buffers are stored in a sparse Array indexed by component ID (position in the ComponentTypes TypeList).
    Only Optional[ThinAllocation] for active components (those contained in the archetype) have a value and are allocated; inactive components are stored as None and must not be dereferenced.

    Layout example for 3 component types where only components 0 and 2 are active:
    ```
    +========================+==================================+========================+
    |      Component 0       |      Component 1 (inactive)      |      Component 2       |
    +========================+==================================+========================+
    | alloc[Type0](capacity) | None (inactive)                  | alloc[Type2](capacity) |
    +------------------------+----------------------------------+------------------------+
    ```

    Parameters:
        ComponentTypes: The component types of the world.
    """

    comptime component_manager = ComponentManager[*Self.ComponentTypes]
    """The component manager for the component types. Provides utilities for mapping component types to IDs and validating component types.
    """

    comptime _Columns = Array[_ComponentColumn, length=len(Self.ComponentTypes)]
    """Homogeneous storage for type-erased component columns."""

    var _capacity: Int
    """The capacity of the component storage, i.e. how many entities can be stored without reallocating."""
    var _length: Int
    """The current length of the component storage, i.e. how many entities are currently stored."""
    var _columns: Self._Columns
    """The component data, with lifecycle operations erased per column."""

    var _active_component_mask: BitMask
    """Ids of the active components in the archetype."""

    def __init__(
        out self,
        active_component_mask: BitMask,
        *,
        length: Int = 0,
        capacity: Int = DEFAULT_CAPACITY,
    ):
        """Initializes component storage for a specific archetype mask.

        Args:
            active_component_mask: The mask describing which component buffers are active.
            length: The initial number of populated entity rows.
            capacity: The initial storage capacity.
        """
        with Zone(
            function_name=(
                "_ComponentTable.__init__(active_component_mask: BitMask,"
                " length: Int, capacity: Int)"
            )
        ):
            self._columns = Self._Columns(fill=_ComponentColumn())
            self._capacity = capacity
            self._length = length
            self._active_component_mask = active_component_mask

            comptime for id in range(len(Self.ComponentTypes)):
                comptime T = Self.ComponentTypes[id]
                self._columns[id] = _ComponentColumn.create[T](
                    preallocate=active_component_mask.get(id),
                    capacity=capacity,
                )

    def __init__(out self, *, copy: Self):
        """Deep-copies the component storage to a new instance, including allocating new buffers and copying component data.

        Returns:
            A deep copy of the component storage with its own allocations.
        """
        with Zone(function_name="_ComponentTable.__init__(copy: Self)"):
            self._columns = Self._Columns(fill=_ComponentColumn())
            self._capacity = copy._capacity
            self._length = copy._length
            self._active_component_mask = copy._active_component_mask

            comptime for id in range(len(Self.ComponentTypes)):
                comptime T = Self.ComponentTypes[id]
                self._columns[id] = _ComponentColumn.create[T](
                    preallocate=False, capacity=self._capacity
                )
                self._columns[id].copy_data_from(
                    copy._columns[id],
                    self._length,
                    self._capacity,
                )

    @always_inline
    def __len__(self) -> Int:
        """
        Gets the current length (number of stored entities) of the component storage.

        Returns:
            The current length of the component storage.
        """
        with Zone(function_name="_ComponentTable.__len__()"):
            return self._length

    @always_inline
    def __deinit__(deinit self):
        """Destroys and frees all active component buffers."""

        with Zone(function_name="_ComponentTable.__del__()"):
            var capacity = self._capacity
            var length = self._length

            def destroy_column(var column: _ComponentColumn) {imm}:
                column.destroy(length, capacity)

            self._columns^.deinit_with(destroy_column)

    @always_inline
    def get_component_count(self) -> Int:
        """Returns the number of active components in the storage.

        Returns:
            The number of active component types.
        """
        with Zone(function_name="_ComponentTable.get_component_count()"):
            return self._active_component_mask.total_bits_set()

    @always_inline
    def add_entity(mut self) -> Int:
        """Adds an entity to the storage (increments length, checks capacity).

        Returns:
            The index of the newly added entity.
        """
        with Zone(function_name="_ComponentTable.add_entity()"):
            if self._length == self._capacity:
                self.reserve(max(self._capacity * 2, 8))
            var idx = self._length
            self._length += 1
            return idx

    @always_inline
    def clear(mut self):
        """Removes all entities from the storage (resets length to 0).

        Note: does not free any memory.
        """
        with Zone(function_name="_ComponentTable.clear()"):
            self._length = 0

    @always_inline
    def reserve(mut self, new_capacity: Int):
        """Extends the capacity of the storage to at least the specified number of entities.

        Uses a power-of-2 allocation strategy. The actual allocated capacity will be the next
        power of 2 greater than or equal to the requested capacity.

        Does nothing if the requested capacity is not larger than the current capacity.

        Args:
            new_capacity: The minimum required capacity. The actual allocated capacity
                         will be `next_power_of_two(new_capacity)` to maintain power-of-2 growth.
        """
        with Zone(function_name="_ComponentTable.reserve(new_capacity: Int)"):
            debug_assert(
                0 < new_capacity, "New capacity must be greater than zero."
            )

            if new_capacity <= self._capacity:
                return

            var new_pow2_capacity = next_power_of_two(new_capacity)
            var old_capacity = self._capacity

            if old_capacity > 0 or self._length == 0:
                for ref column in self._columns:
                    column.resize(self._length, old_capacity, new_pow2_capacity)

            self._capacity = new_pow2_capacity

    @always_inline
    def reserve(mut self, *, add: Int):
        """
        Reserves additional capacity for at least `add` amount of entities.

        Args:
            add: The minimum number of additional entities to reserve capacity for.
        """

        with Zone(function_name="_ComponentTable.reserve(add: Int)"):
            debug_assert(
                0 <= add, "Amount of additional entities must be non-negative"
            )

            self.reserve(self._length + add)

    @always_inline
    def swap_remove_entity(mut self, remove_idx: Int) -> Bool:
        """Performs a swap-remove operation for entity at idx, moving last entity to idx.

        Swaps component data for all active components between idx and new_size (last entity).

        Args:
            remove_idx: The index of the entity to remove.

        Returns:
            Whether a swap was performed (i.e. idx was not the last entity).
        """
        with Zone(
            function_name="_ComponentTable.swap_remove_entity(remove_idx: Int)"
        ):
            _assert_index_in_bounds(remove_idx, self._length)

            self._length -= 1

            var need_swap = remove_idx != self._length

            for ref column in self._columns:
                if column._data:
                    column.swap_remove(self._length + 1, remove_idx)
            return need_swap

    @always_inline
    def get_component_ptr[
        T: ComponentType,
    ](ref self) raises LarecsError -> Pointer[
        T, UntrackedOrigin[mut=origin_of(self).mut]
    ]:
        """Returns the base pointer for the given component type.

        Parameters:
            T: The type of the component.

        Returns:
            The pointer to the component.

        Raises:
            LarecsError: If the component is not contained in the storage.
        """
        with Zone(
            function_name=(
                "_ComponentTable.get_component_ptr[T: ComponentType]()"
            )
        ):
            comptime assert Self.component_manager.contains_components[
                T
            ](), "Component type not in component manager"
            comptime id = Self.component_manager.get_id[T]()

            self.assert_has_components[T]()

            return self._columns[id].get_ptr[T]()

    @always_inline
    def get_component_span[
        T: ComponentType,
    ](ref self) raises LarecsError -> Span[
        T, UntrackedOrigin[mut=origin_of(self).mut]
    ]:
        """Returns a span over all instances in `_ComponentTable` for the given component type.

        Parameters:
            T: The type of the component.

        Returns:
            The span over the component.

        Raises:
            LarecsError: If the component is not contained in the storage.
        """
        with Zone(
            function_name=(
                "_ComponentTable.get_component_span[T: ComponentType]()"
            )
        ):
            comptime assert Self.component_manager.contains_components[
                T
            ](), "Component type not in component manager"
            comptime id = Self.component_manager.get_id[T]()

            self.assert_has_components[T]()

            return Span(
                unsafe_ptr=self._columns[id].get_ptr[T](), length=len(self)
            )

    @always_inline
    def has_components[*Ts: ComponentType](self) -> Bool:
        """Returns whether the storage contains all the given component types.
        """
        with Zone(
            function_name="_ComponentTable.has_components[*Ts: ComponentType]()"
        ):
            Self.component_manager.assert_valid_components[*Ts]()
            comptime comp_mask = BitMask(
                Self.component_manager.get_id_arr[*Ts]()
            )
            return self._active_component_mask.contains(comp_mask)

    @always_inline
    def assert_has_components[*Ts: ComponentType](self) raises LarecsError:
        """Raises if the storage does not contain all the given component types.

        Parameters:
            Ts: The types of the components to check.

        Raises:
            LarecsError: If at least one of the components is not contained in the storage.
        """
        with Zone(
            function_name=(
                "_ComponentTable.assert_has_components[*Ts: ComponentType]()"
            )
        ):
            Self.component_manager.assert_valid_components[*Ts]()

        if not self.has_components[*Ts]():
            raise LarecsError(
                ComponentError.missing_components_on_assert.with_components(
                    BitMask(Self.component_manager.get_id_arr[*Ts]())
                )
            )

    @always_inline
    def set_components[
        *Ts: ComponentType
    ](mut self, entity_idx: Int, var *components: *Ts) raises LarecsError:
        """Sets the component with the given Type T at the given index.

        Parameters:
            Ts: The types of the components to set. Constraints: Must be contained in the component manager and must be unique.

        Args:
            entity_idx: The index of the entity.
            components: The new values of the components.

        Raises:
            LarecsError: If at least one of the components is not present.
        """
        with Zone(
            function_name=(
                "_ComponentTable.set_components[*Ts:"
                " ComponentType](entity_idx: Int, var *components: *Ts)"
            )
        ):
            comptime assert constrain_components_unique[
                *Ts
            ](), "Component types must be unique."
            _assert_index_in_bounds(entity_idx, self._length)

            Self.component_manager.assert_valid_components[*Ts]()
            self.assert_has_components[*Ts]()

            @always_inline
            def set_component[
                comp_id: Int
            ](var component: Ts[comp_id]) capturing -> None:
                comptime T = Ts[comp_id]
                var base_comp_ptr: Pointer[
                    T, UntrackedOrigin[mut=origin_of(self).mut]
                ]
                try:
                    base_comp_ptr = self.get_component_ptr[T]()
                except:
                    return assert_unreachable(
                        "Not reachable as component presence was asserted"
                        " before."
                    )
                base_comp_ptr[unsafe_offset=entity_idx] = component^

            (components^).consume_elements[set_component]()

    @always_inline
    def init_components[
        *Ts: ComponentType
    ](mut self, entity_idx: Int, var *components: *Ts) raises LarecsError:
        """Initializes component values in an uninitialized entity row.

        Parameters:
            Ts: The component types to initialize.

        Args:
            entity_idx: The uninitialized entity row index.
            components: The component values to move into the row.

        Raises:
            LarecsError: If at least one component is not present.
        """
        with Zone(
            function_name=(
                "_ComponentTable.init_components[*Ts:"
                " ComponentType](entity_idx: Int, var *components: *Ts)"
            )
        ):
            comptime assert constrain_components_unique[
                *Ts
            ](), "Component types must be unique."
            _assert_index_in_bounds(entity_idx, self._length)

            Self.component_manager.assert_valid_components[*Ts]()
            self.assert_has_components[*Ts]()

            @always_inline
            def init_component[
                comp_id: Int
            ](var component: Ts[comp_id]) capturing -> None:
                comptime T = Ts[comp_id]
                var base_comp_ptr: Pointer[
                    T, UntrackedOrigin[mut=origin_of(self).mut]
                ]
                try:
                    base_comp_ptr = self.get_component_ptr[T]()
                except:
                    return assert_unreachable(
                        "Not reachable as component presence was asserted"
                        " before."
                    )
                base_comp_ptr.unsafe_offset(entity_idx).unsafe_write(component^)

            (components^).consume_elements[init_component]()

    @always_inline
    def copy_component_from[
        T: ComponentType
    ](
        mut self,
        to_idx: Int,
        storage: _ComponentTable,
        count: Int,
        from_idx: Int = 0,
    ) raises LarecsError:
        """Sets the component with the given Type T for multiple consecutive entities starting with the given index.

        Parameters:
            T: The type of the component. Constraints: Must be contained in the component manager.

        Args:
            to_idx: The index of the first entity to set.
            storage: The storage to copy components from. Must not be the same as self!
            count: The number of elements to set.
            from_idx: The index of the first entity in the storage to copy from.

        Raises:
            LarecsError: If the component is not present in the storage.
        """
        with Zone(
            function_name=(
                "_ComponentTable.copy_component_from[T:"
                " ComponentType](to_idx: Int, storage: _ComponentTable,"
                " count: Int, from_idx: Int)"
            )
        ):
            _assert_range_in_bounds(to_idx, count, self._length)
            _assert_range_in_bounds(from_idx, count, storage._length)

            if count == 0:
                return

            unsafe_destroy_n(
                self.get_component_ptr[T]().unsafe_offset(to_idx), count=count
            )

            unsafe_uninit_copy_n[overlapping=False](
                dest=self.get_component_ptr[T]().unsafe_offset(to_idx),
                src=storage.get_component_ptr[T]().unsafe_offset(from_idx),
                count=count,
            )

    @always_inline
    def copy_shared_components_from_unsafe[
        source_origin: Origin,
    ](
        mut self,
        to_idx: Int,
        source: Pointer[Self, source_origin],
        count: Int,
        from_idx: Int = 0,
    ):
        """Copies shared component columns from an unsafe source storage.

        This helper intentionally erases the source origin so callers can copy
        between two distinct archetypes that originate from the same parent
        list. Only components that are active in both storages are copied.

        Args:
            to_idx: The index of the first destination row.
            source: An unsafe pointer to the source storage. Must not point to self!
            count: The number of rows to copy.
            from_idx: The index of the first source row.

        Constraints:
            The source and destination storages must be distinct and their
            shared component columns must have identical layouts.
        """
        with Zone(
            function_name=(
                "_ComponentTable.copy_shared_components_from_unsafe(to_idx:"
                " Int, source: Pointer, count: Int, from_idx: Int)"
            )
        ):
            debug_assert(0 <= count, "Count must be non-negative.")
            _assert_range_in_bounds(to_idx, count, self._length)
            _assert_range_in_bounds(from_idx, count, source[]._length)

            if count == 0:
                return

        comptime for id in range(len(Self.ComponentTypes)):
            comptime T = Self.ComponentTypes[id]
            if self.has_components[T]() and source[].has_components[T]():
                try:
                    unsafe_destroy_n(
                        self.get_component_ptr[T]().unsafe_offset(to_idx),
                        count=count,
                    )
                    unsafe_uninit_copy_n[overlapping=False](
                        dest=self.get_component_ptr[T]().unsafe_offset(to_idx),
                        src=source[]
                        .get_component_ptr[T]()
                        .unsafe_offset(from_idx),
                        count=count,
                    )
                except:
                    assert_unreachable(
                        "Not reachable as component presence was checked"
                        " before."
                    )


struct Archetype[
    *ComponentTypes: ComponentType,
](Boolable, Copyable, Movable, Sized):
    """
    Archetype represents an ECS archetype.

    Parameters:
        ComponentTypes: The component types of the archetype.
    """

    comptime Index = UInt32
    """The type of the index of entities."""

    comptime max_size = BitMask.total_bits
    """The maximal number of components in the archetype."""

    comptime RowAccessor = ArchetypeRowAccessor[
        _,
        *Self.ComponentTypes,
    ]
    """The type of the entity accessors generated by the archetype."""

    var _storage: _ComponentTable[*Self.ComponentTypes]
    """The component storage of the archetype."""

    var _entities: List[Entity]
    """The entities stored in this archetype."""

    var _node_index: Int
    """Index of this archetype's node in the archetype graph."""

    var _mask: BitMask
    """Component mask represented by this archetype."""

    @always_inline
    def __init__(
        out self,
    ):
        """Initializes the zero archetype without any component.

        Returns:
            The zero archetype.
        """
        with Zone(function_name="Archetype.__init__()"):
            self = Self.__init__(0, BitMask(), 0)

    @always_inline
    def __init__(
        out self,
        node_index: Int,
        mask: BitMask,
        capacity: Int = DEFAULT_CAPACITY,
    ):
        """Initializes the archetype based on a given mask.

        Args:
            node_index: The index of the archetype's node in the archetype graph.
            mask: The mask of the archetype's node in the archetype graph.
            capacity: The initial capacity of the archetype.

        Returns:
            The archetype based on the given mask.
        """
        with Zone(
            function_name=(
                "Archetype.__init__(node_index: Int, mask: BitMask, capacity:"
                " Int)"
            )
        ):
            debug_assert(
                0 <= capacity, "Capacity must be greater or equal to zero."
            )
            _assert_index_in_bounds(node_index, Self.max_size)

            self._mask = mask

            self._storage = _ComponentTable[*Self.ComponentTypes](
                mask, capacity=capacity
            )

            self._entities = List[Entity](capacity=capacity)
            self._node_index = node_index

    @always_inline
    def __init__(out self, *, copy: Self):
        """Copies the data from an existing archetype to a new one.

        Args:
            copy: The archetype to copy from.
        """
        with Zone(function_name="Archetype.__init__(copy: Self)"):
            # Copy the attributes that can be trivially
            # copied via a simple assignment
            self._entities = copy._entities.copy()
            self._node_index = copy._node_index
            self._mask = copy._mask

            # Copy the data
            self._storage = copy._storage.copy()

    @always_inline
    def __len__(self) -> Int:
        """Returns the number of entities in the archetype.

        Returns:
            The number of entities in the archetype.
        """
        with Zone(function_name="Archetype.__len__()"):
            return len(self._storage)

    @always_inline
    def __bool__(self) -> Bool:
        """Returns whether the archetype contains entities.

        Returns:
            Whether the archetype contains entities.
        """
        with Zone(function_name="Archetype.__bool__()"):
            return Bool(self._entities)

    @always_inline
    def get_node_index(self) -> Int:
        """Returns the index of the archetype's node in the archetype graph.

        Returns:
            The index of the archetype's node in the archetype graph.
        """
        with Zone(function_name="Archetype.get_node_index()"):
            return self._node_index

    @always_inline
    def get_mask(self) -> ref[self._mask] BitMask:
        """Returns the mask of the archetype's node in the archetype graph.

        Returns:
            The mask of the archetype's node in the archetype graph.
        """
        with Zone(function_name="Archetype.get_mask()"):
            return self._mask

    @always_inline
    def reserve(mut self):
        """Extends the capacity of the archetype by factor 2 using power-of-2 allocation strategy.

        Doubles the current capacity (minimum 8) to provide exponential growth that minimizes
        the frequency of memory reallocations while maintaining reasonable memory usage.
        This follows standard container growth patterns optimized for amortized performance.
        """
        with Zone(function_name="Archetype.reserve()"):
            self.reserve(max(self._storage._capacity * 2, 8))

    @always_inline
    def reserve(mut self, new_capacity: Int):
        """Extends the capacity of the archetype to at least the specified number of entities.

        Uses a power-of-2 allocation strategy to ensure optimal memory alignment and reduce
        fragmentation. The actual allocated capacity will be the next power of 2 greater than
        or equal to the requested capacity.

        Does nothing if the requested capacity is not larger than the current capacity,
        avoiding unnecessary work and maintaining existing memory layout.

        Args:
            new_capacity: The minimum required capacity. The actual allocated capacity
                         will be `next_power_of_two(new_capacity)` to maintain power-of-2 growth.

        Example:

        ```mojo
        # Requesting 100 entities will allocate capacity for 128 (next power of 2)
        archetype.reserve(100)  # Actually reserves 128

        # Requesting 64 entities allocates exactly 64 (already power of 2)
        archetype.reserve(64)   # Actually reserves 64
        ```
        """
        with Zone(function_name="Archetype.reserve(new_capacity: Int)"):
            self._storage.reserve(new_capacity)
            self._entities.reserve(self._storage._capacity)

    @__unsafe_nested_origins_read_only
    @always_inline
    def get_entity(
        self, idx: Int
    ) -> ref[origin_of(self._entities[idx])] Entity:
        """Returns the entity at the given index.

        Args:
            idx: The index of the entity.

        Returns:
            A reference to the entity at the given index.
        """
        with Zone(function_name="Archetype.get_entity(idx: Int)"):
            _assert_index_in_bounds(idx, self._storage._length)

            return self._entities[idx]

    @__unsafe_nested_origins_read_only
    @always_inline
    def get_row_accessor(
        ref self,
        idx: Int,
        out accessor: Self.RowAccessor[archetype_origin=origin_of(self)],
    ):
        """Returns an accessor for the entity at the given index.

        Args:
            idx: The index of the entity.

        Returns:
            An accessor for the entity at the given index.
        """
        with Zone(
            function_name=(
                "Archetype.get_row_accessor[mut: Bool](idx: Int, out"
                " accessor: Self.RowAccessor)"
            )
        ):
            _assert_index_in_bounds(idx, self._storage._length)

            accessor = Self.RowAccessor(
                self,
                idx,
            )

    @__unsafe_nested_origins_read_only
    @always_inline
    def get_component[
        T: ComponentType
    ](ref self, entity_idx: Int) raises LarecsError -> ref[origin_of(self)] T:
        """Returns the component with the given Type T at the given index.

        Parameters:
            T: The type of the component. Constraints: Must be contained in the component manager.

        Args:
            entity_idx: The index of the entity.

        Raises:
            LarecsError: If the component is not present.

        Returns:
            A reference to the component.
        """
        with Zone(
            function_name=(
                "Archetype.get_component[T: ComponentType](entity_idx: Int)"
            )
        ):
            _assert_index_in_bounds(entity_idx, self._storage._length)

            return self._storage.get_component_ptr[T]()[
                unsafe_offset=entity_idx
            ]

    @always_inline
    def set_components[
        *Ts: ComponentType
    ](mut self, entity_idx: Int, var *components: *Ts) raises LarecsError:
        """Sets the component with the given Type T at the given index.

        Parameters:
            Ts: The types of the components to set. Constraints: Must be contained in the component manager and must be unique.

        Args:
            entity_idx: The index of the entity.
            components: The new values of the components.

        Raises:
            LarecsError: If at least one of the components is not present.
        """
        with Zone(
            function_name=(
                "Archetype.set_components[*Ts: ComponentType](entity_idx: Int,"
                " var *components: *Ts)"
            )
        ):
            self._storage.set_components[*Ts](entity_idx, *components^)

    @always_inline
    def init_components[
        *Ts: ComponentType
    ](mut self, entity_idx: Int, var *components: *Ts) raises LarecsError:
        """Initializes components in an uninitialized entity row.

        Parameters:
            Ts: The component types to initialize.

        Args:
            entity_idx: The uninitialized entity row index.
            components: The component values to move into the row.

        Raises:
            LarecsError: If at least one component is not present.
        """
        with Zone(
            function_name=(
                "Archetype.init_components[*Ts: ComponentType](entity_idx: Int,"
                " var *components: *Ts)"
            )
        ):
            self._storage.init_components[*Ts](entity_idx, *components^)

    @always_inline
    def set_component_range[
        T: ComponentType
    ](mut self, start_entity_idx: Int, count: Int, value: T) raises LarecsError:
        """Fills the component with the given Type T for multiple consecutive entities starting with the given index.

        Parameters:
            T: The type of the component. Constraints: Must be contained in the component manager.

        Args:
            start_entity_idx: The index of the first entity to set.
            count: The number of elements to set.
            value: The value to fill the component with.

        Raises:
            LarecsError: If the component is not present.
        """
        with Zone(
            function_name=(
                "Archetype.set_component_range[T:"
                " ComponentType](start_entity_idx: Int, count: Int, value: T)"
            )
        ):
            _assert_range_in_bounds(
                start_entity_idx, count, self._storage._length
            )

            if count == 0:
                return

            var comp_ptr = self._storage.get_component_ptr[T]()
            Span(
                unsafe_ptr=comp_ptr.unsafe_offset(start_entity_idx),
                length=count,
            ).fill(value)

    @always_inline
    def copy_component_from[
        T: ComponentType
    ](
        mut self,
        to_idx: Int,
        archetype: Archetype,
        count: Int,
        from_idx: Int = 0,
    ) raises LarecsError:
        """Sets the component with the given Type T for multiple consecutive entities starting with the given index.

        Parameters:
            T: The type of the component. Constraints: Must be contained in the component manager.

        Args:
            to_idx: The index of the first entity to set.
            archetype: The archetype to copy components from.
            count: The number of elements to set.
            from_idx: The index of the first entity in the archetype to copy from.

        Raises:
            LarecsError: If the component is not present.
        """

        with Zone(
            function_name=(
                "Archetype.copy_component_from[T: ComponentType](to_idx: Int,"
                " archetype: Archetype, count: Int, from_idx: Int)"
            )
        ):
            self._storage.copy_component_from[T](
                to_idx, archetype._storage, count, from_idx
            )

    @always_inline
    def get_entities(self) -> ref[self._entities] List[Entity]:
        """Returns the entities in the archetype.

        Returns:
            A reference to the entities in the archetype.
        """
        with Zone(function_name="Archetype.get_entities()"):
            return self._entities

    @always_inline
    def has_components[*Ts: ComponentType](self) -> Bool:
        """Returns whether the archetype contains the given component id.

        Parameters:
            Ts: The types of the component. Constraints: Must be contained in the component manager of the storage.

        Returns:
            Whether the archetype contains the component.
        """
        with Zone(
            function_name="Archetype.has_components[*Ts: ComponentType]()"
        ):
            return self._storage.has_components[*Ts]()

    @always_inline
    def assert_has_components[*Ts: ComponentType](self) raises LarecsError:
        """Raises if the archetype does not contain the given component id.

        Parameters:
            Ts: The types of the component. Constraints: Must be contained in the component manager of the storage.

        Raises:
            LarecsError: If the archetype does not contain the component.
        """
        with Zone(
            function_name=(
                "Archetype.assert_has_components[*Ts: ComponentType]()"
            )
        ):
            self._storage.assert_has_components[*Ts]()

    @always_inline
    def remove(mut self, idx: Int) -> Bool:
        """Removes an entity and its components from the archetype.

        Performs a swap-remove and reports whether a swap was necessary
        (i.e. not the last entity that was removed).

        Args:
            idx: The index of the entity to remove.

        Returns:
            Whether a swap was necessary.
        """
        with Zone(function_name="Archetype.remove(idx: Int)"):
            var swapped = self._storage.swap_remove_entity(idx)

            if swapped:
                ref entity = self._entities.pop()
                self._entities[idx] = entity
            else:
                _ = self._entities.pop()

            return swapped

    @always_inline
    def clear(mut self):
        """Removes all entities from the archetype.

        Note: does not free any memory.
        """
        with Zone(function_name="Archetype.clear()"):
            self._entities.clear()
            self._storage.clear()

    @always_inline
    def add_entity(mut self, entity: Entity) -> Int:
        """Adds an entity to the archetype.

        Args:
            entity: The entity to add.

        Returns:
            The index of the entity in the archetype.
        """
        with Zone(function_name="Archetype.add(entity: Entity)"):
            debug_assert(
                len(self._entities) == len(self._storage),
                (
                    "`Archetype._entities` and `Archetype._storage` length"
                    " mismatch."
                ),
            )
            var idx = self._storage.add_entity()
            self._entities.insert(idx, entity)

            return idx

    @always_inline
    def extend_from_archetype_unsafe[
        source_origin: Origin,
    ](
        mut self,
        source: Pointer[Self, source_origin],
        count: Int,
        from_idx: Int = 0,
    ) -> Int:
        """Appends entities and shared components from another archetype.

        This helper is intended for internal batch migration paths where the
        caller has already proven that source and destination archetypes are
        distinct, but Mojo's alias analysis cannot express that relationship.

        Args:
            source: An unsafe pointer to the source archetype. Must not point to self!
            count: The number of entities to append.
            from_idx: The index of the first source entity to append.

        Returns:
            The index of the first newly appended entity.

        Constraints:
            The source and destination archetypes must be distinct and
            contiguous ranges `[from_idx, from_idx + count)` and
            `[return, return + count)` must be valid for the source and
            destination storages.
        """
        with Zone(
            function_name=(
                "Archetype.extend_from_archetype_unsafe(source: Pointer,"
                " count: Int, from_idx: Int)"
            )
        ):
            debug_assert(0 <= count, "Count must be non-negative.")
            debug_assert(
                Pointer(to=self) != source,
                "Source and destination archetypes must be distinct.",
            )
            _assert_range_in_bounds(from_idx, count, len(source[]))

            var start_index = self._storage._length

            if count == 0:
                return start_index

            self._storage.reserve(add=count)
            self._storage._length += count
            self._entities.reserve(self._storage._capacity)

            for i in range(count):
                self._entities.append(source[]._entities[from_idx + i])

            debug_assert(
                start_index + count <= self._storage._length,
                "Destination range must be valid after extending the storage.",
            )

            comptime for id in range(len(Self.ComponentTypes)):
                comptime T = Self.ComponentTypes[id]
                if self.has_components[T]() and source[].has_components[T]():
                    try:
                        unsafe_uninit_copy_n[overlapping=False](
                            dest=self._storage.get_component_ptr[
                                T
                            ]().unsafe_offset(start_index),
                            src=source[]
                            ._storage.get_component_ptr[T]()
                            .unsafe_offset(
                                from_idx,
                            ),
                            count=count,
                        )
                    except:
                        assert_unreachable(
                            "Unreachable as component presence is checked"
                            " before."
                        )

            return start_index

    @always_inline
    def extend(
        mut self,
        count: Int,
        mut entity_pool: EntityPool,
    ) -> Int:
        """Extends the archetype by `count` entities from the provided pool.

        Args:
            count: The number of entities to add.
            entity_pool: The pool to get the entities from.

        Returns:
            The index of the first newly added entity in the
            archetype. The other new entities are at consecutive
            `count` indices.
        """
        with Zone(
            function_name=(
                "Archetype.extend(count: Int, mut entity_pool: EntityPool)"
            )
        ):
            debug_assert(count > 0, "Count must be positive.")

            var start_index = self._storage._length

            self._storage.reserve(
                add=count
            )  # `reserve` handles calculating a good capacity to use
            self._storage._length += count
            self._entities.reserve(
                self._storage._capacity
            )  # use the capacity calculated by `reserve` for the entities list as well

            for _ in range(count):
                self._entities.append(entity_pool.get())

            return start_index
