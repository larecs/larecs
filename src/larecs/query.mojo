from std.utils.type_functions import ConditionalType

from tracy import Zone

from .entity import Entity
from .bitmask import BitMask
from .component import (
    ComponentType,
    ComponentManager,
    constrain_components_unique,
)
from .archetype import Archetype as _Archetype
from .storage import Storage
from .lock import LockManager
from .debug_utils import debug_warn
from .static_optional import StaticOptional
from .error import LarecsError, WorldError


struct Query[
    archetype_mutability: Bool,
    //,
    archetypes_origin: Origin[mut=archetype_mutability],
    locks_origin: MutOrigin,
    *ComponentTypes: ComponentType,
    has_without_mask: Bool = False,
](ImplicitlyCopyable, SizedRaising):
    """Query builder for entities with and without specific components.

    This type should not be used directly, but through the [..storage.Storage.query] method:

    ```mojo {doctest="query_init" global=true hide=true}
    from larecs import World, Resources, MutableEntityAccessor
    ```

    ```mojo {doctest="query_init"}
    world = World[Float64, Float32, Int]()
    _ = world.storage.add_entity(Float64(1.0), Float32(2.0), 3)
    _ = world.storage.add_entity(Float64(1.0), 3)

    for entity in world.storage.query[Float64, Int]():
        ref f = entity.get[Float64]()
        f += 1
    ```

    Parameters:
        archetype_mutability: Whether the archetypes are mutable.
        archetypes_origin: The origin of the archetypes.
        locks_origin: The origin of the lock manager.
        ComponentTypes: The types of the components to include in the query.
        has_without_mask: Whether the query has excluded components.
    """

    comptime Storage = Storage[*Self.ComponentTypes]
    """The world type for this query."""
    comptime ArchetypeIterator = _ArchetypeIterator[
        _,
        *Self.ComponentTypes,
    ]
    """The archetype iterator type for this query."""

    comptime QueryWithWithout = Query[
        Self.archetypes_origin,
        Self.locks_origin,
        *Self.ComponentTypes,
        has_without_mask=True,
    ]
    """The query type with an active exclusion mask."""

    var _archetypes: Pointer[Self.Storage.Archetypes, Self.archetypes_origin]
    """Pointer to the world's archetypes."""
    var _lock_ptr: Pointer[LockManager, Self.locks_origin]
    """Pointer to the world's lock manager."""

    var _info: QueryInfo[has_without_mask=Self.has_without_mask]
    """Component matching information for this query."""

    @doc_hidden
    def __init__(
        out self,
        archetypes: Pointer[Self.Storage.Archetypes, Self.archetypes_origin],
        lock_ptr: Pointer[LockManager, Self.locks_origin],
        var mask: BitMask,
        var without_mask: StaticOptional[BitMask, Self.has_without_mask] = None,
    ):
        """
        Creates a new query.

        The constructors should not be used directly, but through the [..storage.Storage.query] method.

        Args:
            archetypes: A pointer to the world's archetypes.
            lock_ptr: A pointer to the world's lock manager.
            mask: The mask of the components to iterate over.
            without_mask: The mask for components to exclude.
        """
        with Zone(
            function_name=(
                "Query.__init__(archetypes: Pointer, lock_ptr: Pointer, var"
                " mask: BitMask, var without_mask: StaticOptional[BitMask,"
                " Self.has_without_mask])"
            )
        ):
            self._archetypes = archetypes
            self._lock_ptr = lock_ptr
            self._info = QueryInfo[has_without_mask=Self.has_without_mask](
                mask^, without_mask^
            )

    @doc_hidden
    def __init__(
        out self,
        archetypes: Pointer[Self.Storage.Archetypes, Self.archetypes_origin],
        lock_ptr: Pointer[LockManager, Self.locks_origin],
        var info: QueryInfo[has_without_mask=Self.has_without_mask],
    ):
        """
        Creates a new query from existing query information.

        The constructors should not be used directly, but through the [..storage.Storage.query] method.

        Args:
            archetypes: A pointer to the world's archetypes.
            lock_ptr: A pointer to the world's lock manager.
            info: The query information to use for matching.
        """
        with Zone(
            function_name=(
                "Query.__init__(archetypes: Pointer, lock_ptr: Pointer, var"
                " info: QueryInfo)"
            )
        ):
            self._archetypes = archetypes
            self._lock_ptr = lock_ptr
            self._info = info^

    def __init__(out self, *, copy: Self):
        """
        Copy constructor.

        Args:
            copy: The query to copy.
        """
        with Zone(function_name="Query.__init__(copy: Self)"):
            self._archetypes = copy._archetypes
            self._lock_ptr = copy._lock_ptr
            self._info = copy._info.copy()

    def __len__(self, out size: Int):
        """
        Returns the number of entities matching the query.

        Note that this requires the creation of an iterator from the query.
        If you intend to iterate anyway, get the iterator with [.Query.__iter__],
        and call `len` on it, instead.
        """
        with Zone(function_name="Query.__len__(out size: Int)"):
            size = 0
            for i in range(len(self._archetypes[])):
                ref archetype = self._archetypes[].unsafe_get(i)
                if archetype and self._info.matches(archetype.get_mask()):
                    size += len(archetype)

    @always_inline
    def __iter__(
        deinit self,
        out iterator: _WorldEntityIterator[
            Self.archetypes_origin,
            Self.locks_origin,
            *Self.ComponentTypes,
            has_start_indices=False,
        ],
    ) raises LarecsError:
        """
        Creates an iterator over all entities that match the query.

        Raises:
            LarecsError: If the iterator cannot acquire a lock.

        Returns:
            An iterator over all entities that match the query.
        """
        with Zone(function_name="Query.__iter__(out iterator: _WorldIterator)"):
            iterator = {
                self._archetypes,
                self._info^,
                self._lock_ptr,
                None,
            }

    @always_inline
    def without[
        *Ts: ComponentType
    ](deinit self, out query: Self.QueryWithWithout):
        """
        Excludes the given components from the query.

        ```mojo {doctest="query_without" global=true hide=true}
        from larecs import World, Resources, MutableEntityAccessor
        ```

        ```mojo {doctest="query_without"}
        world = World[Float64, Float32, Int]()
        _ = world.add_entity(Float64(1.0), Float32(2.0), 3)
        _ = world.storage.add_entity(Float64(1.0), 3)

        for entity in world.storage.query[Float64, Int]().without[Float32]():
            ref f = entity.get[Float64]()
            f += 1
        ```

        Parameters:
            Ts: The types of the components to exclude.

        Returns:
            The query, excluding the given components.
        """
        with Zone(
            function_name=(
                "Query.without[*Ts: ComponentType](out query:"
                " Self.QueryWithWithout)"
            )
        ):
            comptime assert constrain_components_unique[
                *Ts
            ](), "Duplicate component types in query are not allowed."

            query = Self.QueryWithWithout(
                self._archetypes,
                self._lock_ptr,
                self._info
                ^.without(
                    BitMask(Self.Storage.component_manager.get_id_arr[*Ts]())
                ),
            )

    @always_inline
    def exclusive(deinit self, out query: Self.QueryWithWithout):
        """
        Makes the query only match entities with exactly the query's components.

        ```mojo {doctest="query_without" global=true hide=true}
        from larecs import World, Resources, MutableEntityAccessor
        ```

        ```mojo {doctest="query_without"}
        world = World[Float64, Float32, Int]()
        _ = world.add_entity(Float64(1.0), Float32(2.0), 3)
        _ = world.storage.add_entity(Float64(1.0), 3)

        for entity in world.storage.query[Float64, Int]().exclusive():
            ref f = entity.get[Float64]()
            f += 1
        ```

        Returns:
            The query, made exclusive.
        """
        with Zone(
            function_name="Query.exclusive(out query: Self.QueryWithWithout)"
        ):
            query = Self.QueryWithWithout(
                self._archetypes, self._lock_ptr, self._info^.exclusive()
            )


struct QueryInfo[
    has_without_mask: Bool = False,
](ImplicitlyCopyable):
    """
    Class that holds the same information as a query but no reference to the world.

    This struct can be constructed implicitly from a [.Query] instance.
    Therefore, [.Query] instances can be used instead of QueryInfo in function
    arguments.

    Parameters:
        has_without_mask: Whether the query has excluded components.
    """

    var mask: BitMask
    """Component mask that matching archetypes must contain."""
    var without_mask: StaticOptional[BitMask, Self.has_without_mask]
    """Optional component mask that matching archetypes must not contain."""

    comptime QueryInfoWithWithout = QueryInfo[has_without_mask=True]
    """Query information type with an active exclusion mask."""

    @implicit
    def __init__(
        out self,
        query: Query[..., has_without_mask=Self.has_without_mask],
    ):
        """
        Takes the query info from an existing query.

        Args:
            query: The query the information should be taken from.
        """
        with Zone(function_name="QueryInfo.__init__(query: Query)"):
            self.mask = query._info.mask
            self.without_mask = query._info.without_mask.copy()

    def __init__(
        out self,
        mask: BitMask,
        without_mask: StaticOptional[BitMask, Self.has_without_mask] = None,
    ):
        """
        Takes the query info from an existing query.

        Args:
            mask: The mask of the components to include.
            without_mask: The optional mask of the components to exclude.
        """
        with Zone(
            function_name=(
                "QueryInfo.__init__(mask: BitMask, without_mask:"
                " StaticOptional[BitMask, Self.has_without_mask])"
            )
        ):
            self.mask = mask

            comptime if Self.has_without_mask:
                self.without_mask = without_mask.copy()
            else:
                self.without_mask = None

    def __init__(out self, *, copy: Self):
        """
        Copy constructor.

        Args:
            copy: The query to copy.
        """
        with Zone(function_name="QueryInfo.__init__(copy: Self)"):
            self.mask = copy.mask
            self.without_mask = copy.without_mask.copy()

    @always_inline
    def without(
        deinit self,
        var without_mask: BitMask,
        out query_info: Self.QueryInfoWithWithout,
    ):
        """
        Adds excluded components to the query information.

        Args:
            without_mask: The component mask to exclude.

        Returns:
            Query information with an active exclusion mask.
        """
        with Zone(
            function_name=(
                "QueryInfo.without(var without_mask: BitMask, out query_info:"
                " Self.QueryInfoWithWithout)"
            )
        ):
            comptime if Self.has_without_mask:
                self.without_mask[] |= without_mask
                query_info = Self.QueryInfoWithWithout(
                    self.mask^, self.without_mask[]
                )
            else:
                query_info = Self.QueryInfoWithWithout(
                    self.mask^, without_mask^
                )

    @always_inline
    def exclusive(deinit self, out query_info: Self.QueryInfoWithWithout):
        """
        Makes the query information match exactly the included components.

        Returns:
            Query information with an exclusion mask for all non-included components.
        """
        with Zone(
            function_name=(
                "QueryInfo.exclusive(out query_info: Self.QueryInfoWithWithout)"
            )
        ):
            comptime if Self.has_without_mask:
                self.without_mask = ~self.mask
                query_info = Self.QueryInfoWithWithout(
                    self.mask^, self.without_mask[]
                )
            else:
                query_info = Self.QueryInfoWithWithout(self.mask^, ~self.mask)

    def matches(self, archetype_mask: BitMask, out is_valid: Bool):
        """
        Checks whether the given archetype mask matches the query.

        Args:
            archetype_mask: The mask of the archetype to check.

        Returns:
            Whether the archetype matches the query.
        """
        with Zone(
            function_name=(
                "QueryInfo.matches(archetype_mask: BitMask, out is_valid: Bool)"
            )
        ):
            is_valid = archetype_mask.contains(self.mask)

            comptime if Self.has_without_mask:
                is_valid &= not archetype_mask.contains_any(self.without_mask[])


struct _ArchetypeIterator[
    archetype_mutability: Bool,
    //,
    archetype_origin: Origin[mut=archetype_mutability],
    *ComponentTypes: ComponentType,
](Boolable, Copyable, Iterator, Movable, Sized):
    """
    Iterator over non-empty archetypes corresponding to given list of Archetype IDs.

    Note: For internal use only! Do not expose to users.

    Parameters:
        archetype_mutability: Whether the reference to the archetypes is mutable.
        archetype_origin: The origin of the archetypes.
        ComponentTypes: The types of the components.
    """

    comptime Archetype = _Archetype[*Self.ComponentTypes]
    comptime Element = Self.Archetype
    var _archetypes: Pointer[List[Self.Archetype], Self.archetype_origin]
    var _archetype_indices: List[Int]
    var _index: Int

    def __init__(
        out self,
        archetypes: Pointer[List[Self.Archetype], Self.archetype_origin],
        var archetype_indices: List[Int],
    ):
        """
        Creates an archetype by list iterator.

        Args:
            archetypes: a pointer to the world's archetypes.
            archetype_indices: The indices of the archetypes in the list that are being iterated over.
        """
        with Zone(
            function_name=(
                "_ArchetypeIterator.__init__(archetypes:"
                " Pointer[List[Self.Archetype]], var archetype_indices:"
                " List[Int])"
            )
        ):
            self._archetypes = archetypes
            self._archetype_indices = archetype_indices^
            self._index = 0

    def __init__(
        out self,
        archetypes: Pointer[List[Self.Archetype], Self.archetype_origin],
        var query_info: QueryInfo[has_without_mask=_],
    ):
        """
        Creates an archetype iterator from a list of archetypes and a query info.
        """
        with Zone(
            function_name=(
                "_ArchetypeIterator.__init__(archetypes:"
                " Pointer[List[Self.Archetype]], var query_info: QueryInfo)"
            )
        ):
            self._archetypes = archetypes
            self._archetype_indices = List[Int]()
            self._index = 0

            for i in range(len(self._archetypes[])):
                ref archetype = self._archetypes[].unsafe_get(i)
                if archetype and query_info.matches(archetype.get_mask()):
                    self._archetype_indices.append(i)

    @doc_hidden
    @always_inline
    def __init__(out self, *, copy: Self):
        """
        Copies the iterator state.

        Args:
            copy: The iterator to copy.
        """
        with Zone(function_name="_ArchetypeIterator.__init__(copy: Self)"):
            self._archetypes = copy._archetypes
            self._archetype_indices = copy._archetype_indices.copy()
            self._index = copy._index

    @always_inline
    def __iter__(var self, out iterator: Self):
        """
        Returns self as an iterator usable in for loops.

        Returns:
            Self as an iterator usable in for loops.
        """
        with Zone(
            function_name="_ArchetypeIterator.__iter__(out iterator: Self)"
        ):
            iterator = self^

    @__unsafe_nested_origins_read_only
    @always_inline
    def __next__(
        mut self,
    ) raises StopIteration -> ref[
        origin_of(
            self._archetypes[].unsafe_get(
                self._archetype_indices.unsafe_get(self._index)
            )
        )
    ] Self.Element:
        """
        Returns the next archetype in the iteration.

        Raises:
            StopIteration: If there are no more archetypes to return.

        Returns:
            The next archetype as a pointer.
        """
        with Zone(
            function_name="_ArchetypeIterator.__next__() -> ref Self.Element"
        ):
            if not self._has_next():
                raise StopIteration()
            ref archetype = self._archetypes[].unsafe_get(
                self._archetype_indices.unsafe_get(self._index)
            )

            self._index += 1
            return archetype

    def __len__(self) -> Int:
        """
        Returns the number of archetypes remaining in the iterator.
        """
        with Zone(function_name="_ArchetypeIterator.__len__()"):
            return len(self._archetype_indices) - self._index

    @always_inline
    def _has_next(self) -> Bool:
        """
        Returns whether the iterator has at least one more element.

        Returns:
            Whether there are more elements to iterate.
        """
        with Zone(function_name="_ArchetypeIterator._has_next()"):
            return self._index < len(self._archetype_indices)

    @always_inline
    def __bool__(self) -> Bool:
        """
        Returns whether the iterator has at least one more element.

        Returns:
            Whether there are more elements to iterate.
        """
        with Zone(function_name="_ArchetypeIterator.__bool__()"):
            return self._has_next()


struct _ArchetypeEntityIterator[
    archetype_mutability: Bool,
    //,
    archetype_origin: Origin[mut=archetype_mutability],
    *ComponentTypes: ComponentType,
](Boolable, Movable, Sized):
    """
    Iterator over all entities of an archetype.

    Note: For internal use only! Do not expose to users.

    Parameters:
        archetype_mutability: Whether the archetype references produced by this
            iterator are mutable.
        archetype_origin: The origin of the archetype pointer.
        ComponentTypes: The types of the components.
    """

    comptime Archetype = _Archetype[*Self.ComponentTypes]

    var archetype: Pointer[Self.Archetype, Self.archetype_origin]
    var _index: Int

    def __init__(
        out self,
        ref[Self.archetype_origin] archetype: Self.Archetype,
        _index: Int = 0,
    ):
        """
        Creates an entity iterator for the given archetype.

        Args:
            archetype: An untracked pointer to the archetype to iterate over.
                The caller is responsible for ensuring the pointer remains
                valid for the lifetime of the iterator.
            _index: The index of the entity to start iterating from.
        """
        with Zone(
            function_name=(
                "_ArchetypeEntityIterator.__init__(archetype:"
                " UnsafePointer[UntrackedOrigin], _index: Int)"
            )
        ):
            self.archetype = Pointer(to=archetype)
            self._index = _index

    def _has_next(self) -> Bool:
        """
        Returns whether the iterator has at least one more element.

        Returns:
            Whether there are more elements to iterate.
        """
        with Zone(function_name="_ArchetypeEntityIterator._has_next()"):
            return self._index < len(self.archetype[])

    def __bool__(self) -> Bool:
        """
        Returns whether the iterator has at least one more element.

        Returns:
            Whether there are more elements to iterate.
        """
        with Zone(function_name="_ArchetypeEntityIterator.__bool__()"):
            return self._has_next()

    def __len__(self) -> Int:
        """
        Returns the number of entities remaining in the iterator.
        """
        with Zone(function_name="_ArchetypeEntityIterator.__len__()"):
            return len(self.archetype[]) - self._index

    @__unsafe_nested_origins_read_only
    def __next__(
        mut self,
        out accessor: type_of(
            self.archetype[].get_entity_accessor(self._index)
        ),
    ) raises StopIteration:
        """
        Returns the next entity in the iteration.

        Raises:
            StopIteration: If there are no more entities to iterate.

        Returns:
            An [..archetype.EntityAccessor] to the entity.
        """
        with Zone(
            function_name=(
                "_ArchetypeEntityIterator.__next__[archetype_origin:"
                " Origin](out accessor: Self.Archetype.EntityAccessor)"
            )
        ):
            if not self._has_next():
                raise StopIteration()
            accessor = self.archetype[].get_entity_accessor(self._index)
            self._index += 1


struct _WorldEntityIterator[
    archetype_list_mutability: Bool,
    //,
    archetype_list_origin: Origin[mut=archetype_list_mutability],
    lock_origin: MutOrigin,
    *ComponentTypes: ComponentType,
    has_start_indices: Bool = False,
](Boolable, Movable, Sized):
    """Iterator over all entities of a world corresponding to a mask.

    Locks the world while it exists.

    Parameters:
        archetype_list_mutability: Whether the reference to the archetypes is mutable.
        archetype_list_origin: The origin of the archetypes.
        lock_origin: The origin of the LockManager.
        ComponentTypes: The types of the components.
        has_start_indices: Whether the iterator starts iterating the
                           archetypes at given indices.
    """

    comptime Archetype = _Archetype[*Self.ComponentTypes]
    comptime ArchetypeIterator = _ArchetypeIterator[
        Self.archetype_list_origin,
        *Self.ComponentTypes,
    ]

    # comptime Element = Self.Archetype.EntityAccessor[
    #     Self.archetype_list_origin._get_owned_interior["element"]
    # ]

    # comptime ArchetypeEntityIterator = _ArchetypeEntityIterator[
    #     Self.archetype_list_origin._get_owned_interior["element"],
    #     *Self.ComponentTypes,
    # ]

    comptime IteratorOwnedType = _WorldEntityIterator[
        Self.archetype_list_origin,
        Self.lock_origin,
        *Self.ComponentTypes,
        has_start_indices=Self.has_start_indices,
    ]

    var _lock_ptr: Pointer[LockManager, Self.lock_origin]
    var _lock: Int

    comptime StartIndices = StaticOptional[List[Int], Self.has_start_indices]
    var _start_indices: Self.StartIndices
    var _current_archetype_index: Int

    var _archetype_iterator: Self.ArchetypeIterator

    # We need to store the `_ArchetypeEntityIterator` with an untracked origin, because
    # the interior origins don't carry over from `_WorldEntityIterator` creation to the
    # call of `__next__`. Therefore, we need to reattach the tracked origin via
    # `unsafe_origin_cast`.
    # The same strategy is used in `List` in the standard library.
    # See
    #  - https://github.com/modular/modular/issues/6806
    #  - https://github.com/modular/modular/blob/2b9eb0f719997665d20d19ddeab85fa8a481e871/mojo/stdlib/std/collections/list.mojo#L335
    comptime _UnsafeArchetypeEntityIterator = _ArchetypeEntityIterator[
        UntrackedOrigin[mut=Self.archetype_list_mutability],
        *Self.ComponentTypes,
    ]
    var _entity_iterator: Self._UnsafeArchetypeEntityIterator

    def __init__(
        out self,
        var archetype_iter: Self.ArchetypeIterator,
        lock_ptr: Pointer[LockManager, Self.lock_origin],
        var start_indices: Self.StartIndices = None,
    ) raises LarecsError:
        """
        Creates an entity iterator with or without excluded components.

        Args:
            archetype_iter: The variant of the archetype iterator to use.
            lock_ptr: a pointer to the world's locks.
            start_indices: The indices where the iterator starts iterating the
                           archetypes. Caution: the index order must
                           match the order of the archetypes that
                           are iterated.

        Raises:
            LarecsError: If the lock cannot be acquired.
        """
        with Zone(
            function_name=(
                "_WorldEntityIterator.__init__(var archetype_iter:"
                " Self.ArchetypeIterator, lock_ptr: Pointer, var start_indices:"
                " Self.StartIndices)"
            )
        ):
            self._lock_ptr = lock_ptr
            try:
                self._lock = self._lock_ptr[].lock()
            except:
                raise LarecsError(WorldError.out_of_locks)
            self._start_indices = start_indices^
            self._archetype_iterator = archetype_iter^
            var archetype_list_ptr = (
                self._archetype_iterator._archetypes.unsafe_origin_cast[
                    UntrackedOrigin[mut=Self.archetype_list_mutability]
                ]()
            )
            self._entity_iterator = Self._UnsafeArchetypeEntityIterator(
                archetype_list_ptr[][0],
                len(archetype_list_ptr[][0]),
            )  # initialize entity iterator exhausted so that the first
            # `__next__` always advances to the next archetype; the zero
            # archetype may be non-empty when it is the iteration target.

            self._current_archetype_index = 0

    def __init__(
        out self,
        archetypes: Pointer[List[Self.Archetype], Self.archetype_list_origin],
        var query_info: QueryInfo[has_without_mask=_],
        lock_ptr: Pointer[LockManager, Self.lock_origin],
        var start_indices: Self.StartIndices = None,
    ) raises LarecsError:
        """
        Creates an entity iterator from query information after acquiring a lock.

        Args:
            archetypes: A pointer to the world's archetypes.
            query_info: The query information used to select archetypes.
            lock_ptr: A pointer to the world's locks.
            start_indices: The indices where the iterator starts iterating the
                           archetypes. Caution: the index order must match the
                           order of the archetypes that are iterated.

        Raises:
            LarecsError: If the lock cannot be acquired.
        """
        with Zone(
            function_name=(
                "_WorldEntityIterator.__init__(archetypes:"
                " Pointer[List[Self.Archetype]], var query_info: QueryInfo,"
                " lock_ptr: Pointer, var start_indices: Self.StartIndices)"
            )
        ):
            self._lock_ptr = lock_ptr
            try:
                self._lock = self._lock_ptr[].lock()
            except:
                raise LarecsError(WorldError.out_of_locks)
            self._start_indices = start_indices^

            self._archetype_iterator = Self.ArchetypeIterator(
                archetypes, query_info^
            )
            var archetype_list_ptr = archetypes.unsafe_origin_cast[
                UntrackedOrigin[mut=Self.archetype_list_mutability]
            ]()
            self._entity_iterator = Self._UnsafeArchetypeEntityIterator(
                archetype_list_ptr[][0],
                len(archetype_list_ptr[][0]),
            )  # initialize entity iterator exhausted so that the first
            # `__next__` always advances to the next archetype; the zero
            # archetype may be non-empty when it is the iteration target.

            self._current_archetype_index = 0

    def __del__(deinit self):
        """
        Releases the lock.
        """
        with Zone(function_name="_WorldEntityIterator.__del__()"):
            try:
                self._lock_ptr[].unlock(self._lock)
            except _:
                debug_warn(
                    t"Failed to unlock the lock {self._lock}. This should not"
                    t" happen."
                )

    @always_inline
    def __iter__(var self, out iterator: Self):
        """
        Returns self as an iterator usable in for loops.

        Returns:
            Self as an iterator usable in for loops.
        """
        with Zone(
            function_name="_WorldEntityIterator.__iter__(out iterator: Self)"
        ):
            iterator = self^

    @__unsafe_nested_origins_read_only
    @always_inline
    def __next__(
        mut self,
        out accessor: Self.Archetype.EntityAccessor[Self.archetype_list_origin],
    ) raises StopIteration:
        """
        Returns the next entity in the iteration.

        Raises:
            StopIteration: If there are no more entities to iterate.

        Returns:
            An [..archetype.EntityAccessor] to the entity.
        """

        # Implementation note:
        #
        # The accessor is constructed from the untracked archetype pointer of
        # `self._entity_iterator`, with the tracked whole-list origin
        # reattached via `unsafe_origin_cast`. This is safe because that pointer
        # genuinely points into the archetype list's interior storage for the
        # duration of iteration. Note that the whole-list origin is used (and
        # not an interior element origin of the list): an interior origin in an
        # `out` parameter of a `mut self` method is reported as invalidated by
        # the caller (see `_DequeIter.__next__` in the Mojo stdlib, which uses
        # the whole-container origin for the same reason).

        with Zone(
            function_name=(
                "_WorldEntityIterator.__next__(out accessor: Self.Element)"
            )
        ):
            if not self._entity_iterator:
                if not self._archetype_iterator:
                    raise StopIteration()

                comptime if Self.has_start_indices:
                    start_idx = self._start_indices[][
                        self._current_archetype_index
                    ]
                else:
                    start_idx = 0

                self._current_archetype_index += 1

                var untracked_archetype_ptr = Pointer(
                    to=self._archetype_iterator.__next__()
                ).unsafe_origin_cast[
                    UntrackedOrigin[mut=Self.archetype_list_mutability]
                ]()

                self._entity_iterator = Self._UnsafeArchetypeEntityIterator(
                    untracked_archetype_ptr[],
                    start_idx,
                )

            accessor = {
                self._entity_iterator.archetype.unsafe_origin_cast[
                    Self.archetype_list_origin
                ]()[],
                self._entity_iterator.__next__()._index_in_archetype,
            }

    def __len__(self, out size: Int):
        """
        Returns the number of entities remaining in the iterator.

        Note that this requires iterating over all archetypes
        and may be a complex operation.
        """
        with Zone(function_name="_WorldEntityIterator.__len__(out size: Int)"):
            size = 0

            if not self._has_next():
                return

            if self._entity_iterator:
                size += len(self._entity_iterator)

            archetype_iter_copy = self._archetype_iterator.copy()

            archetype_idx = self._current_archetype_index

            for ref archetype in archetype_iter_copy^:
                comptime if Self.has_start_indices:
                    start_idx = self._start_indices[][archetype_idx]
                else:
                    start_idx = 0
                archetype_idx += 1

                entity_iter = Self._UnsafeArchetypeEntityIterator(
                    Pointer(to=archetype).unsafe_origin_cast[
                        UntrackedOrigin[mut=Self.archetype_list_mutability]
                    ]()[],
                    start_idx,
                )
                size += len(entity_iter)

    @always_inline
    def _has_next(self) -> Bool:
        """
        Returns whether the iterator has at least one more element.

        Returns:
            Whether there are more elements to iterate.
        """
        with Zone(function_name="_WorldEntityIterator._has_next()"):
            return self._entity_iterator or self._archetype_iterator

    @always_inline
    def __bool__(self) -> Bool:
        """
        Returns whether the iterator has at least one more element.

        Returns:
            Whether there are more elements to iterate.
        """
        with Zone(function_name="_WorldEntityIterator.__bool__()"):
            return self._has_next()
