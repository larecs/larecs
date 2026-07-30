from std.sys.defines import is_defined
from std.reflection import reflect
from std.memory import (
    UnsafePointer,
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

comptime MutableEntityAccessor = EntityAccessor[archetype_mutability=True, ...]
"""An entity accessor with mutable references to the components."""


struct EntityAccessor[
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
        out self: EntityAccessor[Self.archetype_origin, *Self.ComponentTypes],
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
                "EntityAccessor.__init__(ref archetype: Self.Archetype,"
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

        with Zone(function_name="EntityAccessor.get_entity()"):
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

        with Zone(function_name="EntityAccessor.get[T: ComponentType]()"):
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
                "EntityAccessor.set[*Ts: ComponentType](var *components: *Ts)"
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
        with Zone(function_name="EntityAccessor.has[T: ComponentType]()"):
            return self._archetype[].has_components[T]()


struct _ComponentStorage[*ComponentTypes: ComponentType](
    Copyable, ImplicitlyDeletable, Movable, Sized
):
    """
    Internal struct to store component data for an archetype.

    UnsafePointers to the component buffers are stored in a sparse tuple indexed by component ID (position in the ComponentTypes TypeList).
    Only pointers for active components (those contained in the archetype) are allocated and valid; inactive components are stored as None and must not be dereferenced.

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

    comptime ComponentPointer[T: ComponentType] = Optional[
        UnsafePointer[T, MutUntrackedOrigin]
    ]
    """The type of the component buffer pointer for a given component type T. Is an optional UnsafePointer, where a present pointer indicates an active component with allocated storage, and None indicates an inactive component without storage.
    """

    comptime _PointerMapper[
        T: ComponentType
    ]: ImplicitlyCopyable & ImplicitlyDeletable & RegisterPassable & Defaultable = Self.ComponentPointer[
        T
    ]
    """Helper type-level function to map component types to their corresponding pointer types in the storage tuple.
    """

    comptime _PointerTuple = Tuple[
        *Self.ComponentTypes.map[Self._PointerMapper]()
    ]
    """The type of the tuple storing component pointers for all component types. See the description of [._ComponentStorage] for the layout and semantics of this tuple.
    """

    var _capacity: Int
    """The capacity of the component storage, i.e. how many entities can be stored without reallocating."""
    var _size: Int
    """The current size of the component storage, i.e. how many entities are currently stored."""
    var _data: Self._PointerTuple
    """The component data, stored as typed pointers to component buffers."""

    var _active_component_mask: BitMask
    """Ids of the active components in the archetype."""

    def __init__(
        out self,
        active_component_mask: BitMask,
        *,
        size: Int = 0,
        capacity: Int = DEFAULT_CAPACITY,
    ):
        """Initializes component storage for a specific archetype mask.

        Args:
            active_component_mask: The mask describing which component buffers are active.
            size: The initial number of populated entity rows.
            capacity: The initial storage capacity.
        """
        with Zone(
            function_name=(
                "_ComponentStorage.__init__(active_component_mask: BitMask,"
                " size: Int, capacity: Int)"
            )
        ):
            self._data = Self._PointerTuple()
            self._capacity = capacity
            self._size = size
            self._active_component_mask = active_component_mask

            self._unsafe_init_components(active_component_mask)

    def __init__(out self, *, copy: Self):
        """Deep-copies the component storage to a new instance, including allocating new buffers and copying component data.

        Returns:
            A deep copy of the component storage with its own allocations.
        """
        with Zone(function_name="_ComponentStorage.__init__(copy: Self)"):
            self = copy.shallow_copy()

            @always_inline
            def copy_component[
                T: ComponentType, id: ComponentId
            ](
                storage_size: Int,
                storage_capacity: Int,
                comp_ptr: Self.ComponentPointer[T],
            ) -> Self.ComponentPointer[T]:
                new_ptr = alloc[T](storage_capacity)
                if storage_size > 0:
                    unsafe_uninit_copy_n[overlapping=False](
                        dest=new_ptr, src=comp_ptr.value(), count=storage_size
                    )
                return rebind[Self.ComponentPointer[T]](Optional(new_ptr))

            self._apply_mut_to_active_components(copy_component)

    @always_inline
    def __len__(self) -> Int:
        """
        Gets the current size (number of stored entities) of the component storage.

        Returns:
            The current size of the component storage.
        """
        with Zone(function_name="_ComponentStorage.__len__()"):
            return self._size

    @always_inline
    def __del__(deinit self):
        """Destroys and frees all active component buffers."""

        with Zone(function_name="_ComponentStorage.__del__()"):

            @always_inline
            def free_component_storage[
                T: ComponentType, id: ComponentId
            ](
                storage_size: Int,
                storage_capacity: Int,
                comp_ptr: UnsafePointer[T, MutUntrackedOrigin],
            ):
                unsafe_destroy_n(pointer=comp_ptr, count=storage_size)
                comp_ptr.free()

            self._apply_to_active_components(free_component_storage)

    def shallow_copy(self, out new_storage: Self):
        """Shallow-copies another component storage instance.

        Returns:
            A shallow copy of the component storage.
        """
        with Zone(
            function_name=(
                "_ComponentStorage.shallow_copy(out new_storage: Self)"
            )
        ):
            # Initialize with an empty active mask to avoid constructing a temporary
            # storage whose active components intentionally have empty pointers.
            new_storage = Self(
                active_component_mask=BitMask(),
                capacity=0,
            )
            new_storage._capacity = self._capacity
            new_storage._size = self._size
            new_storage._active_component_mask = self._active_component_mask
            comptime assert Self.ComponentTypes.map[
                Self._PointerMapper
            ]().all_conforms_to[
                Copyable
            ](), (
                "All component pointer types must be copyable for shallow copy."
            )
            new_storage._data = self._data.copy()

    def _unsafe_init_components(mut self, imm init_component_mask: BitMask):
        """(Re)Initializes owned component storage while keeping the component layout intact.

        Important:
        This is intended for internal ownership-transfer flows where another archetype has
        taken over the old storage pointers and this archetype must regain valid, uniquely
        owned allocations before continuing.

        Args:
            init_component_mask: A bit mask indicating which components should be initialized.

        Note:
            Only active components in this storage are initialized.
        """

        with Zone(
            function_name=(
                "_ComponentStorage._unsafe_init_components(read"
                " init_component_mask: BitMask)"
            )
        ):

            def init_component_ptr[
                T: ComponentType, id: ComponentId
            ](
                storage_size: Int,
                storage_capacity: Int,
                comp_ptr: Self.ComponentPointer[T],
            ) {imm} -> Self.ComponentPointer[T]:
                if init_component_mask.get(id):
                    if storage_capacity > 0:
                        return rebind[Self.ComponentPointer[T]](
                            alloc[T](storage_capacity)
                        )
                    return None
                else:
                    return comp_ptr

            self._apply_mut_to_active_components(init_component_ptr)

    @always_inline
    def get_component_count(self) -> Int:
        """Returns the number of active components in the storage.

        Returns:
            The number of active component types.
        """
        with Zone(function_name="_ComponentStorage.get_component_count()"):
            return self._active_component_mask.total_bits_set()

    @always_inline
    def add_entity(mut self) -> Int:
        """Adds an entity to the storage (increments size, checks capacity).

        Returns:
            The index of the newly added entity.
        """
        with Zone(function_name="_ComponentStorage.add_entity()"):
            if self._size == self._capacity:
                self.reserve(max(self._capacity * 2, 8))
            var idx = self._size
            self._size += 1
            return idx

    @always_inline
    def clear(mut self):
        """Removes all entities from the storage (resets size to 0).

        Note: does not free any memory.
        """
        with Zone(function_name="_ComponentStorage.clear()"):
            self._size = 0

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
        with Zone(function_name="_ComponentStorage.reserve(new_capacity: Int)"):
            debug_assert(
                0 < new_capacity, "New capacity must be greater than zero."
            )

            if new_capacity <= self._capacity:
                return

            var new_pow2_capacity = next_power_of_two(new_capacity)
            var old_capacity = self._capacity

            @always_inline
            def resize_component_storage[
                T: ComponentType, id: ComponentId
            ](
                storage_size: Int,
                storage_capacity: Int,
                old_ptr: Self.ComponentPointer[T],
            ) {imm} -> Self.ComponentPointer[T]:
                var new_ptr = alloc[T](new_pow2_capacity)
                if storage_size > 0:
                    unsafe_uninit_move_n[overlapping=False](
                        dest=new_ptr, src=old_ptr.value(), count=storage_size
                    )
                old_ptr.value().free()
                return rebind[Self.ComponentPointer[T]](Optional(new_ptr))

            if old_capacity > 0 or self._size == 0:
                self._apply_mut_to_active_components(resize_component_storage)

            self._capacity = new_pow2_capacity

    @always_inline
    def reserve(mut self, *, add: Int):
        """
        Reserves additional capacity for at least `add` amount of entities.

        Args:
            add: The minimum number of additional entities to reserve capacity for.
        """

        with Zone(function_name="_ComponentStorage.reserve(add: Int)"):
            debug_assert(
                0 <= add, "Amount of additional entities must be non-negative"
            )

            self.reserve(self._size + add)

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
            function_name=(
                "_ComponentStorage.swap_remove_entity(remove_idx: Int)"
            )
        ):
            _assert_index_in_bounds(remove_idx, self._size)

            self._size -= 1

            need_swap = remove_idx != self._size

            @always_inline
            def swap_component_data[
                T: ComponentType, id: ComponentId
            ](
                storage_size: Int,
                storage_capacity: Int,
                comp_ptr: UnsafePointer[T, MutUntrackedOrigin],
            ) {imm}:
                unsafe_destroy_n(comp_ptr + remove_idx, count=1)
                if need_swap:
                    unsafe_uninit_move_n[overlapping=False](
                        dest=comp_ptr + remove_idx,
                        src=comp_ptr + storage_size,
                        count=1,
                    )

            self._apply_to_active_components(swap_component_data)
            return need_swap

    @always_inline
    def get_component_ptr[
        T: ComponentType,
    ](ref self) raises LarecsError -> UnsafePointer[T, MutUntrackedOrigin]:
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
                "_ComponentStorage.get_component_ptr[T: ComponentType]()"
            )
        ):
            comptime assert Self.component_manager._ContainsComponent[
                T
            ], "Component type not in component manager"
            comptime id = Self.component_manager.get_id[T]()

            self.assert_has_components[T]()

            return rebind[Self.ComponentPointer[T]](self._data[id]).value()

    @always_inline
    def has_components[*Ts: ComponentType](self) -> Bool:
        """Returns whether the storage contains all the given component types.
        """
        with Zone(
            function_name=(
                "_ComponentStorage.has_components[*Ts: ComponentType]()"
            )
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
                "_ComponentStorage.assert_has_components[*Ts: ComponentType]()"
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
                "_ComponentStorage.set_components[*Ts:"
                " ComponentType](entity_idx: Int, var *components: *Ts)"
            )
        ):
            comptime assert constrain_components_unique[
                *Ts
            ](), "Component types must be unique."
            _assert_index_in_bounds(entity_idx, self._size)

            Self.component_manager.assert_valid_components[*Ts]()
            self.assert_has_components[*Ts]()

            @always_inline
            def set_component[
                comp_id: Int
            ](var component: Ts[comp_id]) capturing -> None:
                comptime T = Ts[comp_id]
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
                "_ComponentStorage.init_components[*Ts:"
                " ComponentType](entity_idx: Int, var *components: *Ts)"
            )
        ):
            comptime assert constrain_components_unique[
                *Ts
            ](), "Component types must be unique."
            _assert_index_in_bounds(entity_idx, self._size)

            Self.component_manager.assert_valid_components[*Ts]()
            self.assert_has_components[*Ts]()

            @always_inline
            def init_component[
                comp_id: Int
            ](var component: Ts[comp_id]) capturing -> None:
                comptime T = Ts[comp_id]
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
        storage: _ComponentStorage,
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
                "_ComponentStorage.copy_component_from[T:"
                " ComponentType](to_idx: Int, storage: _ComponentStorage,"
                " count: Int, from_idx: Int)"
            )
        ):
            _assert_range_in_bounds(to_idx, count, self._size)
            _assert_range_in_bounds(from_idx, count, storage._size)

            if count == 0:
                return

            unsafe_destroy_n(self.get_component_ptr[T]() + to_idx, count=count)

            unsafe_uninit_copy_n[overlapping=False](
                dest=self.get_component_ptr[T]() + to_idx,
                src=storage.get_component_ptr[T]() + from_idx,
                count=count,
            )

    @always_inline
    def copy_shared_components_from_unsafe[
        source_origin: Origin,
    ](
        mut self,
        to_idx: Int,
        source: UnsafePointer[Self, source_origin],
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
                "_ComponentStorage.copy_shared_components_from_unsafe(to_idx:"
                " Int, source: UnsafePointer, count: Int, from_idx: Int)"
            )
        ):
            debug_assert(0 <= count, "Count must be non-negative.")
            _assert_range_in_bounds(to_idx, count, self._size)
            _assert_range_in_bounds(from_idx, count, source[]._size)

            if count == 0:
                return

        comptime for id in range(len(Self.ComponentTypes)):
            comptime T = Self.ComponentTypes[id]
            if self.has_components[T]() and source[].has_components[T]():
                try:
                    unsafe_destroy_n(
                        self.get_component_ptr[T]() + to_idx, count=count
                    )
                    unsafe_uninit_copy_n[overlapping=False](
                        dest=self.get_component_ptr[T]() + to_idx,
                        src=source[].get_component_ptr[T]() + from_idx,
                        count=count,
                    )
                except:
                    assert_unreachable(
                        "Not reachable as component presence was checked"
                        " before."
                    )

    @always_inline
    def _apply_mut_to_active_components[
        FuncType: def[T: ComponentType, id: ComponentId](
            storage_size: Int,
            storage_capacity: Int,
            comp_ptr: Self.ComponentPointer[T],
        ) -> Self.ComponentPointer[T],
    ](mut self, func: FuncType):
        """Applies a function to each active component pointer, allowing mutation of the pointers by returning new pointers.

        Parameters:
            FuncType: The type of the function to apply to each active component pointer.

        Args:
            func: A function that takes a component ID and the corresponding typed pointer, and performs some mutating operation.
                The function can return a new pointer to replace the existing one in the storage (e.g. for reallocations), which will be updated accordingly.
        """
        with Zone(
            function_name=(
                "_ComponentStorage._apply_mut_to_active_components[FuncType](func:"
                " FuncType)"
            )
        ):
            comptime for id in range(len(Self.ComponentTypes)):
                comptime T = Self.ComponentTypes[id]
                if self.has_components[T]():
                    comp_ptr = rebind[Self.ComponentPointer[T]](self._data[id])
                    self._data[id] = rebind[
                        Self._PointerTuple.element_types[id]
                    ](func[T, id](self._size, self._capacity, comp_ptr))

    def _apply_to_active_components[
        FuncType: def[T: ComponentType, id: ComponentId](
            storage_size: Int,
            storage_capacity: Int,
            comp_ptr: UnsafePointer[T, MutUntrackedOrigin],
        ),
    ](self, func: FuncType):
        """Applies a function to each active component pointer, allowing mutation of the data pointed to by the pointer but not changing the pointers themselves.

        Parameters:
            FuncType: The type of the function to apply to each active component.

        Args:
            func: A function that takes a component ID and the corresponding typed pointer, and performs some operation.
        """
        with Zone(
            function_name=(
                "_ComponentStorage._apply_to_active_components[FuncType](func:"
                " FuncType)"
            )
        ):
            comptime for id in range(len(Self.ComponentTypes)):
                comptime T = Self.ComponentTypes[id]
                if self.has_components[T]():
                    comp_ptr = rebind[Self.ComponentPointer[T]](self._data[id])
                    func[T, id](
                        self._size, self._capacity, comp_ptr.value().copy()
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

    comptime EntityAccessor = EntityAccessor[
        _,
        *Self.ComponentTypes,
    ]
    """The type of the entity accessors generated by the archetype."""

    var _storage: _ComponentStorage[*Self.ComponentTypes]
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

            self._storage = _ComponentStorage[*Self.ComponentTypes](
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
            _assert_index_in_bounds(idx, self._storage._size)

            return self._entities[idx]

    @__unsafe_nested_origins_read_only
    @always_inline
    def get_entity_accessor(
        ref self,
        idx: Int,
        out accessor: Self.EntityAccessor[archetype_origin=origin_of(self)],
    ):
        """Returns an accessor for the entity at the given index.

        Args:
            idx: The index of the entity.

        Returns:
            An accessor for the entity at the given index.
        """
        with Zone(
            function_name=(
                "Archetype.get_entity_accessor[mut: Bool](idx: Int, out"
                " accessor: Self.EntityAccessor)"
            )
        ):
            _assert_index_in_bounds(idx, self._storage._size)

            accessor = Self.EntityAccessor(
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
            _assert_index_in_bounds(entity_idx, self._storage._size)

            return self._storage.get_component_ptr[T]()[entity_idx]

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
                start_entity_idx, count, self._storage._size
            )

            if count == 0:
                return

            var comp_ptr = self._storage.get_component_ptr[T]()
            Span(unsafe_ptr=comp_ptr + start_entity_idx, length=count).fill(
                value
            )

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
                "`Archetype._entities` and `Archetype._storage` size mismatch.",
            )
            var idx = self._storage.add_entity()
            self._entities.insert(idx, entity)

            return idx

    @always_inline
    def extend_from_archetype_unsafe[
        source_origin: Origin,
    ](
        mut self,
        source: UnsafePointer[Self, source_origin],
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
                "Archetype.extend_from_archetype_unsafe(source: UnsafePointer,"
                " count: Int, from_idx: Int)"
            )
        ):
            debug_assert(0 <= count, "Count must be non-negative.")
            debug_assert(
                UnsafePointer(to=self) != source,
                "Source and destination archetypes must be distinct.",
            )
            _assert_range_in_bounds(from_idx, count, len(source[]))

            start_index = self._storage._size

            if count == 0:
                return start_index

            self._storage.reserve(add=count)
            self._storage._size += count
            self._entities.reserve(self._storage._capacity)

            for i in range(count):
                self._entities.append(source[]._entities[from_idx + i])

            debug_assert(
                start_index + count <= self._storage._size,
                "Destination range must be valid after extending the storage.",
            )

            comptime for id in range(len(Self.ComponentTypes)):
                comptime T = Self.ComponentTypes[id]
                if self.has_components[T]() and source[].has_components[T]():
                    try:
                        unsafe_uninit_copy_n[overlapping=False](
                            dest=self._storage.get_component_ptr[T]()
                            + start_index,
                            src=source[]._storage.get_component_ptr[T]()
                            + from_idx,
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

            start_index = self._storage._size

            self._storage.reserve(
                add=count
            )  # `reserve` handles calculating a good capacity to use
            self._storage._size += count
            self._entities.reserve(
                self._storage._capacity
            )  # use the capacity calculated by `reserve` for the entities list as well

            for _ in range(count):
                self._entities.append(entity_pool.get())

            return start_index
