from .bitmask import BitMask
from .component import (
    ComponentType,
    ComponentManager,
    constrain_components_unique,
)
from .error import LarecsError, ComponentError
from ._utils import (
    assert_unreachable,
    _assert_range_in_bounds,
    _assert_index_in_bounds,
)

from std.reflection.traits import AllCopyable
from std.memory import UnsafePointer, uninit_copy_n, uninit_move_n, destroy_n
from std.bit import next_power_of_two


struct Archetype(Copyable):
    var component_mask: BitMask


struct DeviceId(Equatable, ImplicitlyCopyable):
    var _id: Int

    comptime no_device = Self(_id=0)
    comptime host = Self(_id=1)
    comptime gpu = Self(_id=2)

    @always_inline
    def __init__(out self, _id: Int):
        debug_assert(_id >= 0 and _id <= 2, "DeviceId must be between 0 and 2")
        self._id = _id


@fieldwise_init
struct Location(ImplicitlyCopyable):
    var device_id: DeviceId
    var storage_id: Int


@fieldwise_init
struct Header(Copyable):
    var archetype: Archetype

    var authoritative_for: BitMask

    var size: Int
    var capacity: Int

    var location: Location


trait LarecsPhase:
    comptime phase_id: Int


struct LightPhase(LarecsPhase):
    comptime phase_id = 0


struct GrowPhase(LarecsPhase):
    comptime phase_id = 1


scheduler.add_phase(LightPhase)
scheduler.add_phase[GrowPhase, depends_on=LightPhase]

scheduler.run[MySystem]()


struct MySystem:
    comptime ImmComponents = [Foo]
    comptime MutComponents = [Foo]
    comptime Resources = [Bar]
    comptime Phase = LightPhase
    comptime prefers_gpu = True

    def update(context):
        ref bar = context.resource[Bar]()
        for ref foo in context.query[Foo]():
            foo.x += 1


struct StorageController[*ComponentTypes: ComponentType]:
    comptime HostStorage = HostStorage[*Self.ComponentTypes]
    comptime GpuStorage = GpuStorage[*Self.ComponentTypes]

    var metadata: List[Header]
    var host_storages: List[Self.HostStorage]
    var gpu_storages: List[Self.GpuStorage]

    def __init__(out self):
        self.metadata = []
        self.host_storages = []
        self.gpu_storages = []

    def _get_next_location[on_device: DeviceId](self) -> Location:
        comptime if on_device == DeviceId.host:
            return Location(
                device_id=on_device, storage_id=len(self.host_storages)
            )
        elif on_device == DeviceId.gpu:
            return Location(
                device_id=on_device, storage_id=len(self.gpu_storages)
            )
        else:
            return Location(device_id=DeviceId.no_device, storage_id=0)

    def add_archetype[
        on_device: DeviceId
    ](mut self, archetype: Archetype, *, initial_capacity: Int):
        var location = self._get_next_location[on_device]()

        var meta = Header(
            archetype=archetype.copy(),
            authoritative_for=archetype.component_mask,
            size=0,
            capacity=initial_capacity,
            location=location,
        )

        self.metadata.append(meta^)

        comptime if on_device == DeviceId.host:
            self.host_storages.append(
                Self.HostStorage(archetype.component_mask)
            )
        elif on_device == DeviceId.gpu:
            self.gpu_storages.append(Self.GpuStorage())


struct Position(Copyable):
    var x: Float32
    var y: Float32
    var z: Float32


struct Velocity(Copyable):
    var dx: Float32
    var dy: Float32
    var dz: Float32


struct Name(Copyable):
    var text: String


def test_storage() raises:
    var storage = StorageController[Position, Velocity, Name]()


comptime DEFAULT_CAPACITY = 32


struct GpuStorage[*ComponentTypes: ComponentType](
    Copyable, ImplicitlyDeletable, Movable, Sized
):
    def __init__(out self):
        pass

    def __len__(self) -> Int:
        return 0


struct HostStorage[*ComponentTypes: ComponentType](
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
                uninit_copy_n[overlapping=False](
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
        return self._size

    @always_inline
    def __del__(deinit self):
        """Destroys and frees all active component buffers."""

        @always_inline
        def free_component_storage[
            T: ComponentType, id: ComponentId
        ](
            storage_size: Int,
            storage_capacity: Int,
            comp_ptr: UnsafePointer[T, MutUntrackedOrigin],
        ):
            destroy_n(comp_ptr, count=storage_size)
            comp_ptr.free()

        self._apply_to_active_components(free_component_storage)

    def shallow_copy(self, out new_storage: Self):
        """Shallow-copies another component storage instance.

        Returns:
            A shallow copy of the component storage.
        """
        # Initialize with an empty active mask to avoid constructing a temporary
        # storage whose active components intentionally have empty pointers.
        new_storage = Self(
            active_component_mask=BitMask(),
            capacity=0,
        )
        new_storage._capacity = self._capacity
        new_storage._size = self._size
        new_storage._active_component_mask = self._active_component_mask
        comptime assert AllCopyable[
            *Self.ComponentTypes.map[Self._PointerMapper]()
        ]
        new_storage._data = self._data.copy()

    def _unsafe_init_components(mut self, read init_component_mask: BitMask):
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

        def init_component_ptr[
            T: ComponentType, id: ComponentId
        ](
            storage_size: Int,
            storage_capacity: Int,
            comp_ptr: Self.ComponentPointer[T],
        ) {read} -> Self.ComponentPointer[T]:
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
        return self._active_component_mask.total_bits_set()

    @always_inline
    def add_entity(mut self) -> Int:
        """Adds an entity to the storage (increments size, checks capacity).

        Returns:
            The index of the newly added entity.
        """
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
        ) {read} -> Self.ComponentPointer[T]:
            var new_ptr = alloc[T](new_pow2_capacity)
            if storage_size > 0:
                uninit_move_n[overlapping=False](
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
        ) {read}:
            destroy_n(comp_ptr + remove_idx, count=1)
            if need_swap:
                uninit_move_n[overlapping=False](
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
        Self.component_manager.assert_valid_components[*Ts]()
        comptime comp_mask = BitMask(Self.component_manager.get_id_arr[*Ts]())
        return self._active_component_mask.contains(comp_mask)

    @always_inline
    def assert_has_components[*Ts: ComponentType](self) raises LarecsError:
        """Raises if the storage does not contain all the given component types.

        Parameters:
            Ts: The types of the components to check.

        Raises:
            LarecsError: If at least one of the components is not contained in the storage.
        """
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
                    "Not reachable as component presence was asserted before."
                )
            entity_comp_ptr = base_comp_ptr + entity_idx
            destroy_n(entity_comp_ptr, 1)
            entity_comp_ptr.init_pointee_move(component^)

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
                    "Not reachable as component presence was asserted before."
                )
            entity_comp_ptr = base_comp_ptr + entity_idx
            entity_comp_ptr.init_pointee_move(component^)

        (components^).consume_elements[init_component]()

    @always_inline
    def copy_component_from[
        T: ComponentType
    ](
        mut self,
        to_idx: Int,
        storage: HostStorage,
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
        _assert_range_in_bounds(to_idx, count, self._size)
        _assert_range_in_bounds(from_idx, count, storage._size)

        if count == 0:
            return

        destroy_n(self.get_component_ptr[T]() + to_idx, count=count)

        uninit_copy_n[overlapping=False](
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
        debug_assert(0 <= count, "Count must be non-negative.")
        _assert_range_in_bounds(to_idx, count, self._size)
        _assert_range_in_bounds(from_idx, count, source[]._size)

        if count == 0:
            return

        comptime for id in range(len(Self.ComponentTypes)):
            comptime T = Self.ComponentTypes[id]
            if self.has_components[T]() and source[].has_components[T]():
                try:
                    destroy_n(self.get_component_ptr[T]() + to_idx, count=count)
                    uninit_copy_n[overlapping=False](
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
        comptime for id in range(len(Self.ComponentTypes)):
            comptime T = Self.ComponentTypes[id]
            if self.has_components[T]():
                comp_ptr = rebind[Self.ComponentPointer[T]](self._data[id])
                self._data[id] = rebind[Self._PointerTuple.element_types[id]](
                    func[T, id](self._size, self._capacity, comp_ptr)
                )

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
        comptime for id in range(len(Self.ComponentTypes)):
            comptime T = Self.ComponentTypes[id]
            if self.has_components[T]():
                comp_ptr = rebind[Self.ComponentPointer[T]](self._data[id])
                func[T, id](self._size, self._capacity, comp_ptr.value().copy())
