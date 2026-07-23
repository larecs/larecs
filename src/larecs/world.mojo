from std.memory import UnsafePointer
from std.collections import Span
from std.sys import size_of
from std.algorithm.backend.vectorize import vectorize
from std.builtin.globals import global_constant

from tracy import Zone

from .pool import EntityPool
from .entity import Entity, EntityLocation
from .archetype import (
    Archetype as _Archetype,
    MutableEntityAccessor,
)
from .graph import BitMaskGraph
from .bitmask import BitMask
from .debug_utils import debug_warn
from .component import (
    ComponentManager,
    ComponentType,
    constrain_components_unique,
)
from .bitmask import BitMask
from .static_optional import StaticOptional
from .query import (
    Query,
    QueryInfo,
    _WorldEntityIterator,
    _ArchetypeIterator,
)
from .lock import LockManager
from .resource import Resources
from ._utils import concatenate_inline_arrays, assert_unreachable
from .types import ComponentId
from .error import (
    LarecsError,
    UnknownError,
    ComponentError,
    WorldError,
    EntityError,
)


@fieldwise_init
struct Replacer[
    world_origin: MutOrigin,
    size: Int,
    *component_types: ComponentType,
    remove_ids: InlineArray[ComponentId, size],
]:
    """
    Replacer is a helper struct for removing and adding components to an [..entity.Entity].

    It stores the components to remove and allows adding new components
    in one go.

    Parameters:
        world_origin: The mutable origin of the world.
        size: The number of components to remove.
        component_types: The types of the components.
        remove_ids: The IDs of the components to remove.
    """

    comptime World = World[*Self.component_types]
    """The world type modified by this replacer."""

    var _world: Pointer[Self.World, Self.world_origin]
    """Pointer to the world modified by this replacer."""

    def by(self, entity: Entity) raises LarecsError:
        """
        Removes components from an [..entity.Entity].

        Args:
            entity: The entity to modify.

        Raises:
            Error: when called for a removed (and potentially recycled) entity.
            Error: when called with components that can't be removed because they are not present.
            Error: when called on a locked world. Do not use during [.World.query] iteration.
        """
        with Zone(function_name="Replacer.by(entity: Entity)"):
            self._world[]._remove_and_add[
                rem_size=Self.size,
                remove_ids=Self.remove_ids,
            ](entity)

    def by[
        T: ComponentType
    ](self, var component: T, *, entity: Entity) raises LarecsError:
        """
        Removes components from and adds one component to an [..entity.Entity].

        Parameters:
            T: The type of the component to add.

        Args:
            component: The component to add.
            entity:    The entity to modify.

        Raises:
            Error: when called for a removed (and potentially recycled) entity.
            Error: when called with components that can't be added because they are already present.
            Error: when called with components that can't be removed because they are not present.
            Error: when called on a locked world. Do not use during [.World.query] iteration.
        """
        with Zone(
            function_name=(
                "Replacer.by[T: ComponentType](var component: T, entity:"
                " Entity)"
            )
        ):
            self._world[]._remove_and_add[
                T,
                rem_size=Self.size,
                remove_ids=Self.remove_ids,
            ](entity, component^)

    def by[
        *AddTs: ComponentType
    ](self, var *components: *AddTs, entity: Entity) raises LarecsError:
        """
        Removes and adds the components to an [..entity.Entity].

        Parameters:
            AddTs: The types of the components to add.

        Args:
            components: The components to add.
            entity:     The entity to modify.

        Raises:
            Error: when called for a removed (and potentially recycled) entity.
            Error: when called with components that can't be added because they are already present.
            Error: when called with components that can't be removed because they are not present.
            Error: when called on a locked world. Do not use during [.World.query] iteration.
        """
        with Zone(
            function_name=(
                "Replacer.by[*AddTs: ComponentType](var *components: *AddTs,"
                " entity: Entity)"
            )
        ):
            self._world[]._remove_and_add[
                *AddTs,
                rem_size=Self.size,
                remove_ids=Self.remove_ids,
            ](entity, *components^)

    def by[
        *AddTs: ComponentType,
        has_without_mask: Bool = False,
    ](
        self,
        query: QueryInfo[has_without_mask=has_without_mask],
        var *components: *AddTs,
        out iterator: Self.World.Iterator[
            origin_of(self._world[]._archetypes),
            origin_of(self._world[]._locks),
            has_start_indices=True,
        ],
    ) raises LarecsError:
        """
        Removes and adds the components to multiple [..entity.Entity Entities] specified by a [..query.Query].

        Parameters:
            AddTs: The types of the components to add.
            has_without_mask: Whether the query has a without mask.

        Args:
            query:     The query to determine which entities to modify.
            components: The components to add.

        Raises:
            Error: when called with components that can't be added because they are already present.
            Error: when called with components that can't be removed because they are not present.
            Error: when called on a locked world. Do not use during [.World.query] iteration.
        """
        with Zone(
            function_name=(
                "Replacer.by[*AddTs: ComponentType, has_without_mask:"
                " Bool](query: QueryInfo, var *components: *AddTs, out"
                " iterator: Self.World.Iterator)"
            )
        ):
            return self.by(
                *components^,
                query=query,
            )

    def by[
        *AddTs: ComponentType,
        has_without_mask: Bool = False,
    ](
        self,
        var *components: *AddTs,
        query: QueryInfo[has_without_mask=has_without_mask],
        out iterator: Self.World.Iterator[
            origin_of(self._world[]._archetypes),
            origin_of(self._world[]._locks),
            has_start_indices=True,
        ],
    ) raises LarecsError:
        """
        Removes and adds the components to multiple [..entity.Entity Entities] specified by a [..query.Query].

        Parameters:
            AddTs: The types of the components to add.
            has_without_mask: Whether the query has a without mask.

        Args:
            components: The components to add.
            query:     The query to determine which entities to modify.

        Raises:
            Error: when called with components that can't be added because they are already present.
            Error: when called with components that can't be removed because they are not present.
            Error: when called on a locked world. Do not use during [.World.query] iteration.
        """

        with Zone(
            function_name=(
                "Replacer.by[*AddTs: ComponentType, has_without_mask: Bool](var"
                " *components: *AddTs, query: QueryInfo, out iterator:"
                " Self.World.Iterator)"
            )
        ):
            return self._world[]._batch_remove_and_add[
                rem_size=Self.size,
                remove_ids=Self.remove_ids,
            ](
                query,
                *components^,
            )


struct World[*component_types: ComponentType](Copyable, Movable, Sized):
    """
    World is the central type holding entity and component data, as well as resources.

    The World provides all the basic ECS functionality of Larecs,
    like [.World.query], [.World.add_entity], [.World.add], [.World.remove], [.World.get] or [.World.remove_entity].
    """

    comptime component_manager = ComponentManager[*Self.component_types]()
    """Component manager for this world's component type set."""

    # If *Ts is empty, this results in a zero-sized InlineArray, else this
    # results in an InlineArray of component IDs.
    comptime _optional_component_ids[
        *Ts: ComponentType
    ] = Self.component_manager.get_id_arr[*Ts]()
    """Component ID array type for an optional component type pack."""

    comptime Archetype = _Archetype[*Self.component_types]
    """Archetype type used by this world."""
    comptime Query = Query[
        _,
        _,
        *Self.component_types,
        has_without_mask=_,
    ]
    """Query builder type for this world's component type set."""

    comptime Iterator[
        archetype_mutability: Bool,
        //,
        archetype_origin: Origin[mut=archetype_mutability],
        lock_origin: MutOrigin,
        *,
        has_start_indices: Bool = False,
    ] = _WorldEntityIterator[
        archetype_origin,
        lock_origin,
        *Self.component_types,
        has_start_indices=has_start_indices,
    ]
    """
    Primary entity iterator type comptime for mask-based World queries.

    Parameters:
        archetype_mutability: Whether the iterator allows mutable access to archetypes.
        archetype_origin: The origin of the archetype data accessed by the iterator.
        lock_origin: The origin of the locks used for safe concurrent access.
        has_start_indices: Enables iteration from specific entity ranges (batch ops).
    """

    comptime ArchetypeIterator[
        archetype_mutability: Bool,
        //,
        archetype_origin: Origin[mut=archetype_mutability],
        has_without_mask: Bool = False,
    ] = _ArchetypeIterator[
        archetype_origin,
        *Self.component_types,
    ]
    """
    Archetype iterator type for iterating over archetypes matching a query.

    Parameters:
        archetype_mutability: Whether the iterator allows mutable access to archetypes.
        archetype_origin: The origin of the archetype data accessed by the iterator.
        has_without_mask: Whether the query has a without mask, which requires additional checks during iteration.
    """

    # _listener       Listener                  # EntityEvent _listener.
    # _node_pointers   []*archNode               # Helper list of all node pointers for queries.
    # _tarquery bitSet                    # Whether entities are potential relation targets. Used for archetype cleanup.
    # _relation_nodes  []*archNode               # Archetype nodes that have an entity relation.
    # _filter_cache    Cache                     # Cache for registered filters.
    # _nodes          pagedSlice[archNode]      # The archetype graph.
    # _archetype_data  pagedSlice[_archetype_data] # Storage for the actual archetype data (components).
    # _node_data       pagedSlice[_node_data]      # The archetype graph's data.
    # _stats          _stats.World               # Cached world statistics.
    var _entity_pool: EntityPool  # Pool for entities.
    """Pool used to allocate and recycle entity IDs."""
    var _entities: List[
        EntityLocation
    ]  # Mapping from entities to archetype and index.
    """Mapping from entity IDs to their current archetype location."""
    var _archetype_map: BitMaskGraph[
        -1
    ]  # Mapping from component masks to archetypes.
    """Graph mapping component masks to archetype indices."""
    var _locks: LockManager  # World _locks.
    """Lock manager guarding mutation during active iteration."""

    comptime Archetypes = List[Self.Archetype]
    """Type alias for the list of archetypes owned by the world."""

    var _archetypes: Self.Archetypes
    """Storage for all archetypes owned by the world."""

    var resources: Resources  # The resources of the world.
    """Resource storage associated with the world."""

    def __init__(out self):
        """
        Creates a new [.World].
        """
        with Zone(function_name="World.__init__()"):
            self._archetype_map = BitMaskGraph[-1](0)
            self._archetypes = [Self.Archetype()]
            self._entities = [EntityLocation(0, 0)]
            self._entity_pool = EntityPool()
            self._locks = LockManager()
            self.resources = Resources()

            # TODO
            # var _tarquery = bitSet
            # _tarquery.ExtendTo(1)
            # self._tarquery = _tarquery

            # self._listener:       nil,
            # self._resources:      newResources(),
            # self._filter_cache:    newCache(),

            # var node = self.createArchetypeNode(Mask, ID, false)

    def __len__(self, out size: Int):
        """
        Returns the number of entities in the world.

        Note that this requires iterating over all archetypes and
        may be an expensive operation.
        """
        with Zone(function_name="World.__len__(out size: Int)"):
            size = 0
            for archetype in self._archetypes:
                size += len(archetype)

    @always_inline
    def _get_archetype_index[
        size: Int
    ](
        mut self,
        components: InlineArray[ComponentId, size],
        start_node_index: Int = 0,
    ) -> Int:
        """Returns the archetype list index of the archetype
        with the given component indices.

        If necessary, creates a new archetype.

        Args:
            components:       The components that distinguish the archetypes.
            start_node_index: The index of the start archetype's node.

        Returns:
            The archetype list index of the archetype differing from the start
            archetype by the components at the given indices.

        Constraints:
            `size` must be non-negative.
        """
        with Zone(
            function_name=(
                "World._get_archetype_index[size: Int](components:"
                " InlineArray[ComponentId, size], start_node_index: Int)"
            )
        ):
            comptime assert 0 <= size, "Size must be non-negative."
            node_index = self._archetype_map.get_node_index(
                components, start_node_index
            )
            if self._archetype_map.has_value(node_index):
                return self._archetype_map[node_index]

            archetype_index = len(self._archetypes)
            self._archetypes.insert(
                archetype_index,
                Self.Archetype(
                    node_index,
                    self._archetype_map.get_node_mask(node_index),
                ),
            )

            self._archetype_map[node_index] = archetype_index

            return archetype_index

    @always_inline
    def _get_archetype_index_by_mask(mut self, var mask: BitMask) -> Int:
        """Returns the archetype list index for an exact component mask.

        Args:
            mask: The exact component mask to find or create.

        Returns:
            The archetype list index for the mask.
        """
        with Zone(
            function_name="World._get_archetype_index_by_mask(mask: BitMask)"
        ):
            for i in range(len(self._archetypes)):
                if self._archetypes[i].get_mask() == mask:
                    return i

            node_index = self._archetype_map.add_node(mask.copy())
            archetype_index = len(self._archetypes)
            self._archetypes.append(Self.Archetype(node_index, mask^))
            self._archetype_map[node_index] = archetype_index
            return archetype_index

    def add_entity[
        *Ts: ComponentType
    ](mut self, var *components: *Ts, out entity: Entity) raises LarecsError:
        """Returns a new or recycled [..entity.Entity].

        The given component types are added to the entity.
        Do not use during [.World.query] iteration!

        ⚠️ Important:
        Entities are intended to be stored and passed around via copy, not via pointers! See [..entity.Entity].

        Example:

        ```mojo {doctest="add_entity_comps" global=true hide=true}
        from larecs import World

        @fieldwise_init
        struct Position(Copyable, Movable):
            var x: Float64
            var y: Float64

        @fieldwise_init
        struct Velocity(Copyable, Movable):
            var x: Float64
            var y: Float64
        ```

        ```mojo {doctest="add_entity_comps"}
        world = World[Position, Velocity]()
        e = world.add_entity(
            Position(0, 0),
            Velocity(0.5, -0.5),
        )
        ```

        Parameters:
            Ts: The components to add to the entity. Constraints: Must contain no duplicates and all components must be in the component manager.

        Args:
            components: The components to add to the entity.

        Raises:
            Error: If the world is [.World.is_locked locked].

        Returns:
            The new or recycled [..entity.Entity].

        """
        with Zone(
            function_name=(
                "World.add_entity[*Ts: ComponentType](var *components: *Ts, out"
                " entity: Entity)"
            )
        ):
            comptime assert Self.component_manager._ContainsComponents[
                *Ts
            ], "Not all component types are in the component manager."
            comptime assert constrain_components_unique[
                *Ts
            ](), "Duplicate component types in add_entity are not allowed."

            self._assert_unlocked()

            comptime component_count = len(Ts)

            comptime if component_count:
                archetype_index = self._get_archetype_index(
                    Self.component_manager.get_id_arr[*Ts]()
                )
            else:
                archetype_index = 0

            entity = self._create_entity(archetype_index)

            comptime if component_count:
                entity_index = self._entities[entity.get_id()].entity_index
                self._archetypes[archetype_index].init_components[*Ts](
                    entity_index, *components^
                )

            # TODO
            # if self._listener != nil:
            #     var newRel *Id
            #     if arch.HasRelationComponent:
            #         newRel = &arch.RelationComponent

            #     var bits = subscription(true, false, len(comps) > 0, false, newRel != nil, newRel != nil)
            #     var trigger = self._listener.Subscriptions() & bits
            #     if trigger != 0 && subscribes(trigger, &arch.Mask, nil, self._listener.Components(), nil, newRel):
            #         self._listener.Notify(self, EntityEventEntity: entity, Added: arch.Mask, AddedIDs: comps, NewRelation: newRel, EventTypes: bits)

            return

    def add_entities[
        *Ts: ComponentType
    ](
        mut self,
        *components: *Ts,
        count: Int,
        out iterator: Self.Iterator[
            origin_of(self._archetypes),
            origin_of(self._locks),
            has_start_indices=True,
        ],
    ) raises LarecsError:
        """Adds a batch of [..entity.Entity Entities].

        The given component types are added to the entities.
        Do not use during [.World.query] iteration!

        Example:

        ```mojo {doctest="add_entity_comps" global=true hide=true}
        from larecs import World, Resources

        @fieldwise_init
        struct Position(Copyable, Movable):
            var x: Float64
            var y: Float64

        @fieldwise_init
        struct Velocity(Copyable, Movable):
            var x: Float64
            var y: Float64
        ```

        ```mojo {doctest="add_entity_comps"}
        world = World[Position, Velocity]()
        for entity in world.add_entities(
            Position(0, 0),
            Velocity(0.5, -0.5),
            count = 5
        ):
            # Do things with the newly created entities
            position = entity.get[Position]()
        ```

        Parameters:
            Ts: The components to add to the entity. Constraints: Must contain no duplicates and all components must be in the component manager.

        Args:
            components: The components to add to the entity.
            count: The number of entities to add.

        Raises:
            LarecsError: If the world is [.World.is_locked locked].

        Returns:
            An iterator to the new or recycled [..entity.Entity Entities].

        """
        with Zone(
            function_name=(
                "World.add_entities[*Ts: ComponentType](*components: *Ts,"
                " count: Int, out iterator: Self.Iterator)"
            )
        ):
            comptime assert Self.component_manager._ContainsComponents[
                *Ts
            ], "Not all component types are in the component manager."
            comptime assert constrain_components_unique[
                *Ts
            ](), "Duplicate component types in add_entities are not allowed."

            debug_assert(0 <= count, "Count must be non-negative.")

            if count == 0:
                try:
                    iterator = {
                        Self.ArchetypeIterator[
                            origin_of(self._archetypes),
                            has_without_mask=False,
                        ](Pointer(to=self._archetypes), []),
                        Pointer(to=self._locks),
                        {[]},
                    }
                    return
                except _:
                    raise LarecsError(WorldError.out_of_locks)

            self._assert_unlocked()

            comptime component_count = len(Ts)

            comptime if component_count:
                archetype_index = self._get_archetype_index(
                    Self.component_manager.get_id_arr[*Ts]()
                )
            else:
                archetype_index = 0

            first_index_in_archetype = self._create_entities(
                archetype_index, count
            )

            ref archetype = self._archetypes.unsafe_get(archetype_index)

            comptime for i in range(component_count):
                comptime T = Ts[i]
                comptime assert Self.component_manager._ContainsComponent[
                    T
                ], "Component type is not part of the world."
                archetype.set_component_range[T](
                    first_index_in_archetype, count, components[i]
                )

            try:
                iterator = {
                    Self.ArchetypeIterator[
                        origin_of(self._archetypes),
                        has_without_mask=False,
                    ](Pointer(to=self._archetypes), [archetype_index]),
                    Pointer(to=self._locks),
                    {[first_index_in_archetype]},
                }
            except _:
                raise LarecsError(WorldError.out_of_locks)

    @always_inline
    def _create_entity(mut self, archetype_index: Int, out entity: Entity):
        """
        Creates an [..entity.Entity] and adds it to the given archetype.

        The entity's components are left uninitialized.
        Initialize them using [..archetype.Archetype.init_components()] or similar before accessing them!

        Returns:
            The new entity.
        """
        with Zone(
            function_name=(
                "World._create_entity(archetype_index: Int, out entity: Entity)"
            )
        ):
            entity = self._entity_pool.get()
            idx = self._archetypes.unsafe_get(archetype_index).add_entity(
                entity
            )
            if entity.get_id() == len(self._entities):
                self._entities.append(EntityLocation(idx, archetype_index))
            else:
                self._entities[entity.get_id()] = EntityLocation(
                    idx, archetype_index
                )

    @always_inline
    def _create_entities(mut self, archetype_index: Int, count: Int) -> Int:
        """
        Creates multiple [..entity.Entity Entities] and adds them to the given archetype.

        Returns:
            The index of the first newly created entity in the archetype.
        """
        with Zone(
            function_name=(
                "World._create_entities(archetype_index: Int, count: Int)"
            )
        ):
            debug_assert(count > 0, "Count must be positive.")
            ref archetype = self._archetypes.unsafe_get(archetype_index)
            arch_start_idx = archetype.extend(count, self._entity_pool)
            entities_size = (
                archetype.get_entity(arch_start_idx + count - 1).get_id() + 1
            )
            if entities_size > len(self._entities):
                if entities_size > self._entities.capacity():
                    self._entities.reserve(
                        max(entities_size, 2 * self._entities.capacity())
                    )

                self._entities.resize(
                    entities_size, EntityLocation(0, archetype_index)
                )

            for i in range(arch_start_idx, arch_start_idx + count):
                entity_id = archetype.get_entity(i).get_id()
                self._entities[entity_id].archetype_index = archetype_index
                self._entities[entity_id].entity_index = i

            return arch_start_idx

    def remove_entity(mut self, entity: Entity) raises LarecsError:
        """
        Removes an [..entity.Entity], making it eligible for recycling.

        Do not use during [.World.query] iteration!

        Args:
            entity: The entity to remove.

        Raises:
            LarecsError: If the world is locked or the entity does not exist.
        """
        self._assert_unlocked()
        self._assert_alive(entity)

        with Zone(function_name="World.remove_entity(entity: Entity)"):
            entity_loc = self._entities[entity.get_id()]
            ref old_archetype = self._archetypes.unsafe_get(
                entity_loc.archetype_index
            )

            # if self._listener != nil:
            #     var oldRel *Id
            #     if old_archetype.HasRelationComponent:
            #         oldRel = &old_archetype.RelationComponent

            #     var oldIds []Id
            #     if len(old_archetype.node.Ids) > 0:
            #         oldIds = old_archetype.node.Ids

            #     var bits = subscription(false, true, false, len(oldIds) > 0, oldRel != nil, oldRel != nil)
            #     var trigger = self._listener.Subscriptions() & bits
            #     if trigger != 0 && subscribes(trigger, nil, &old_archetype.Mask, self._listener.Components(), oldRel, nil):
            #         var lock = self.lock()
            #         self._listener.Notify(self, EntityEventEntity: entity, Removed: old_archetype.Mask, RemovedIDs: oldIds, OldRelation: oldRel, OldTarget: old_archetype.RelationTarget, EventTypes: bits)
            #         self.unlock(lock)

            swapped = old_archetype.remove(entity_loc.entity_index)

            try:
                self._entity_pool.recycle(entity)
            except:
                assert_unreachable(
                    "Zero Entity should never be handed via public API. So it"
                    " should never be recycled here!"
                )

            if swapped:
                swap_entity = old_archetype.get_entity(entity_loc.entity_index)
                self._entities[
                    swap_entity.get_id()
                ].entity_index = entity_loc.entity_index

    def remove_entities(mut self, query: QueryInfo) raises LarecsError:
        """
        Removes multiple [..entity.Entity Entities] based on the provided query, making them eligible for recycling.

        Example:

        ```mojo {doctest="apply" global=true hide=true}
        from larecs import World, MutableEntityAccessor
        from testing import assert_equal, assert_false
        ```

        ```mojo {doctest="apply"}
        world = World[Float32, Float64]()
        _ = world.add_entity(Float32(0))
        _ = world.add_entity(Float32(0), Float64(0))
        _ = world.add_entity(Float64(0))

        # Remove all entities with a Float32 component.
        world.remove_entities(world.query[Float32]())
        ```

        Args:
            query: The query to determine which entities to remove. Note, you can
                   either use [..query.Query] or [..query.QueryInfo].

        Raises:
            LarecsError: If the world is locked.
        """
        self._assert_unlocked()

        with Zone(function_name="World.remove_entities(query: QueryInfo)"):
            for ref archetype in self._get_archetype_iterator(
                query.mask, query.without_mask
            ):
                for entity in archetype.get_entities():
                    try:
                        self._entity_pool.recycle(entity)
                    except:
                        assert_unreachable(
                            "Zero Entity should never be handed via public API."
                            " So it should never be recycled here!"
                        )
                archetype.clear()

            # if self._listener != nil:
            #     var oldRel *Id
            #     if old_archetype.HasRelationComponent:
            #         oldRel = &old_archetype.RelationComponent

            #     var oldIds []Id
            #     if len(old_archetype.node.Ids) > 0:
            #         oldIds = old_archetype.node.Ids

            #     var bits = subscription(false, true, false, len(oldIds) > 0, oldRel != nil, oldRel != nil)
            #     var trigger = self._listener.Subscriptions() & bits
            #     if trigger != 0 && subscribes(trigger, nil, &old_archetype.Mask, self._listener.Components(), oldRel, nil):
            #         var lock = self.lock()
            #         self._listener.Notify(self, EntityEventEntity: entity, Removed: old_archetype.Mask, RemovedIDs: oldIds, OldRelation: oldRel, OldTarget: old_archetype.RelationTarget, EventTypes: bits)
            #         self.unlock(lock)

    @always_inline
    def is_alive(self, entity: Entity) -> Bool:
        """
        Reports whether an [..entity.Entity] is still alive.

        Args:
            entity: The entity to check.
        """
        with Zone(function_name="World.is_alive(entity: Entity)"):
            return self._entity_pool.is_alive(entity)

    @always_inline
    def has[T: ComponentType](self, entity: Entity) raises LarecsError -> Bool:
        """
        Returns whether an [..entity.Entity] has a given component.

        Parameters:
            T: The type of the component. Constraints: Must be in the component manager.

        Args:
            entity: The entity to check.

        Raises:
            LarecsError: If the entity does not exist.
        """
        with Zone(function_name="World.has[T: ComponentType](entity: Entity)"):
            comptime assert Self.component_manager._ContainsComponent[
                T
            ], "Component type not in component manager"
            self._assert_alive(entity)
            return self._archetypes.unsafe_get(
                index(self._entities[entity.get_id()].archetype_index)
            ).has_components[T]()

    @always_inline
    def get[
        T: ComponentType
    ](mut self, entity: Entity) raises LarecsError -> ref[
        origin_of(
            self._archetypes.unsafe_get(
                self._entities[entity.get_id()].archetype_index
            )
        )
    ] T:
        """Returns a reference to the given component of an [..entity.Entity].

        Parameters:
            T: The type of the component. Constraints: Must be in the component manager.

        Raises:
            LarecsError: If the entity is not alive or does not have the component.
        """
        comptime assert Self.component_manager._ContainsComponent[
            T
        ], "Component type not in component manager"
        entity_loc = self._entities[entity.get_id()]
        self._assert_alive(entity)

        with Zone(function_name="World.get[T: ComponentType](entity: Entity)"):
            if not self._archetypes.unsafe_get(
                entity_loc.archetype_index
            ).has_components[T]():
                raise LarecsError(
                    ComponentError.missing_components_on_assert.with_components(
                        BitMask(Self.component_manager.get_id[T]())
                    )
                )

            return self._archetypes.unsafe_get(
                entity_loc.archetype_index
            ).get_component[T](entity_loc.entity_index)

    @always_inline
    def set[
        T: ComponentType
    ](mut self, entity: Entity, var component: T) raises LarecsError:
        """
        Overwrites a component for an [..entity.Entity], using the given content.

        Parameters:
            T:         The type of the component. Constraints: Must be in the component manager.

        Args:
            entity:    The entity to modify.
            component: The new component.

        Raises:
            Error: If the [..entity.Entity] does not exist.
        """
        with Zone(
            function_name=(
                "World.set[T: ComponentType](entity: Entity, var component: T)"
            )
        ):
            comptime assert Self.component_manager._ContainsComponent[
                T
            ], "Component type not in component manager"
            self._assert_alive(entity)
            entity_loc = self._entities[entity.get_id()]
            self._archetypes.unsafe_get(
                entity_loc.archetype_index
            ).set_components[T](entity_loc.entity_index, component^)

    @always_inline
    def set[
        *Ts: ComponentType
    ](mut self, entity: Entity, var *components: *Ts) raises LarecsError:
        """
        Overwrites components for an [..entity.Entity] using the given content.

        Parameters:
            Ts:        The types of the components. Constraints: Must be in the component manager and contain no duplicates.

        Args:
            entity:    The entity to modify.
            components: The new components.

        Raises:
            Error: If the entity does not exist.
            Error: If the entity does not have one of the components.
        """
        with Zone(
            function_name=(
                "World.set[*Ts: ComponentType](entity: Entity, var *components:"
                " *Ts)"
            )
        ):
            comptime assert Self.component_manager._ContainsComponents[
                *Ts
            ], "One or more component types not in component manager"
            comptime assert constrain_components_unique[
                *Ts
            ](), "Duplicate component types in set are not allowed."

            self._assert_alive(entity)
            entity_loc = self._entities[entity.get_id()]
            self._archetypes.unsafe_get(
                entity_loc.archetype_index
            ).set_components[*Ts](entity_loc.entity_index, *components^)

    def add[
        *Ts: ComponentType
    ](mut self, entity: Entity, var *add_components: *Ts) raises LarecsError:
        """
        Adds components to an [..entity.Entity].

        Parameters:
            Ts: The types of the components to add.

        Args:
            entity:         The entity to modify.
            add_components: The components to add.

        Raises:
            Error: when called for a removed (and potentially recycled) entity.
            Error: when called with components that can't be added because they are already present.
            Error: when called on a locked world. Do not use during [.World.query] iteration.
        """
        with Zone(
            function_name=(
                "World.add[*Ts: ComponentType](entity: Entity, var"
                " *add_components: *Ts)"
            )
        ):
            self._remove_and_add(entity, *add_components^)

    def add[
        *Ts: ComponentType
    ](mut self, var *add_components: *Ts, entity: Entity) raises LarecsError:
        """
        Adds components to an [..entity.Entity].

        Parameters:
            Ts: The types of the components to add.

        Args:
            add_components: The components to add.
            entity:         The entity to modify.

        Raises:
            Error: when called for a removed (and potentially recycled) entity.
            Error: when called with components that can't be added because they are already present.
            Error: when called on a locked world. Do not use during [.World.query] iteration.
        """
        with Zone(
            function_name=(
                "World.add[*Ts: ComponentType](var *add_components: *Ts,"
                " entity: Entity)"
            )
        ):
            self._remove_and_add(entity, *add_components^)

    def add[
        has_without_mask: Bool, //, *Ts: ComponentType
    ](
        mut self,
        query: QueryInfo[has_without_mask=has_without_mask],
        var *add_components: *Ts,
        out iterator: Self.Iterator[
            origin_of(self._archetypes),
            origin_of(self._locks),
            has_start_indices=True,
        ],
    ) raises LarecsError:
        """
        Adds components to multiple [..entity.Entity Entities] at once that are specified by a [..query.Query].
        The provided query must ensure that matching entities do not already have one or more of the
        components to add.

        **Example:**

        ```mojo {doctest="add_query_comps" global=true}
        from larecs import World

        @fieldwise_init
        struct Position(Copyable, Movable):
            var x: Float64
            var y: Float64

        @fieldwise_init
        struct Velocity(Copyable, Movable):
            var x: Float64
            var y: Float64

        world = World[Position, Velocity]()
        _ = world.add_entities(Position(0, 0), 100)

        for entity in world.add[Velocity](
            world.query[Position]().without_mask[Velocity](),
            Velocity(0.5, -0.5),
        ):
            velocity = entity.get[Velocity]()
            position = entity.get[Position]()
            entity.set[Position](Position(position.x + velocity.x, position.y + velocity.y))
            entity.set[Velocity](Velocity(velocity.x - 0.05, velocity.y - 0.05))
        ```

        Parameters:
            has_without_mask: Whether the query has a without mask.
            Ts: The types of the components to add. Constraints: Must be in the component manager and contain no duplicates.

        Args:
            query: The query specifying which entities to modify. The query must explicitly exclude existing entities
                that already have some of the components to add.
            add_components: The components to add.

        Raises:
            Error: when called on a locked world. Do not use during [.World.query] iteration.
            Error: when called with a query that could match existing entities that already have at least one of the
                components to add.
        """
        with Zone(
            function_name=(
                "World.add[has_without_mask: Bool, *Ts: ComponentType](query:"
                " QueryInfo, var *add_components: *Ts, out iterator:"
                " Self.Iterator)"
            )
        ):
            comptime assert Self.component_manager._ContainsComponents[
                *Ts
            ], "One or more component types not in component manager"
            comptime assert constrain_components_unique[
                *Ts
            ](), "Duplicate component types in add are not allowed."

            return self._batch_remove_and_add(
                query,
                *add_components^,
            )

    def remove[*Ts: ComponentType](mut self, entity: Entity) raises LarecsError:
        """
        Removes components from an [..entity.Entity].

        Parameters:
            Ts: The types of the components to remove.

        Args:
            entity: The entity to modify.

        Raises:
            Error: when called for a removed (and potentially recycled) entity.
            Error: when called with components that can't be removed because they are not present.
            Error: when called on a locked world. Do not use during [.World.query] iteration.
        """
        with Zone(
            function_name="World.remove[*Ts: ComponentType](entity: Entity)"
        ):
            comptime assert constrain_components_unique[
                *Ts
            ](), "Duplicate component types in remove are not allowed."

            self._remove_and_add[
                rem_size=len(Ts),
                remove_ids=Self._optional_component_ids[*Ts],
            ](
                entity,
            )

    def remove[
        *Ts: ComponentType, has_without_mask: Bool = False
    ](
        mut self,
        query: QueryInfo[has_without_mask=has_without_mask],
        out iterator: Self.Iterator[
            origin_of(self._archetypes),
            origin_of(self._locks),
            has_start_indices=True,
        ],
    ) raises LarecsError:
        """
        Removes components from multiple entities at once, specified by a [..query.Query].
        The provided query must ensure that matching entities have all of the components that should get removed.

        Example:

        ```mojo {doctest="remove_query_comps" global=true}
        from larecs import World

        @fieldwise_init
        struct Position(Copyable, Movable):
            var x: Float64
            var y: Float64

        @fieldwise_init
        struct Velocity(Copyable, Movable):
            var x: Float64
            var y: Float64

        world = World[Position, Velocity]()
        _ = world.add_entities(Position(0, 0), Velocity(1, 0), 100)

        for entity in world.remove[Velocity](
            world.query[Position, Velocity]()
        ):
            position = entity.get[Position]()
        ```

        Parameters:
            Ts: The types of the components to remove. Constraints: Must be in the component manager and contain no duplicates.
            has_without_mask: Whether the query has a without mask.

        Args:
            query: The query to determine which entities to modify.

        Raises:
            Error: when called on a locked world. Do not use during [.World.query] iteration.
            Error: when called with a query that could match entities that don't have all of the components to remove.
        """

        with Zone(
            function_name=(
                "World.remove[*Ts: ComponentType, has_without_mask:"
                " Bool](query: QueryInfo, out iterator: Self.Iterator)"
            )
        ):
            # Note:
            #     This operation can never map multiple archetypes onto one, due to the requirement that components to remove
            #     must be already present on archetypes matched by the query. Therefore, we can apply the transformation to
            #     each matching archetype individually, without checking for edge cases where multiple archetypes get merged
            #     into one.  This also enables potential parallelization optimizations.
            comptime assert constrain_components_unique[
                *Ts
            ](), "Duplicate component types in remove are not allowed."
            comptime assert Self.component_manager._ContainsComponents[
                *Ts
            ], "One or more component types not in component manager"

            return self._batch_remove_and_add[
                rem_size=len(Ts),
                remove_ids=Self._optional_component_ids[*Ts],
            ](query)

    @always_inline
    def replace[
        *Ts: ComponentType
    ](mut self) -> Replacer[
        origin_of(self),
        len(Ts),
        *Self.component_types,
        remove_ids=Self.component_manager.get_id_arr[*Ts](),
    ]:
        """
        Returns a [.Replacer] for removing and adding components to an [..entity.Entity] in one go.

        Use as `world.replace[Comp1, Comp2]().by(comp3, comp4, comp5, entity=entity)`.

        The number of removed components does not need to match the number of added components.

        Parameters:
            Ts: The types of the components to remove.
        """
        with Zone(function_name="World.replace[*Ts: ComponentType]()"):
            comptime assert constrain_components_unique[
                *Ts
            ](), "Duplicate component types in replace are not allowed."

            return {Pointer(to=self)}

    @always_inline
    def _remove_and_add[
        *Ts: ComponentType,
        rem_size: Int = 0,
        remove_ids: InlineArray[ComponentId, rem_size] = [],
    ](mut self, entity: Entity, var *add_components: *Ts) raises LarecsError:
        """
        Adds and removes components to an [..entity.Entity].

        Parameters:
            Ts:          The types of the components to add. Constraints: Must be in the component manager and contain no duplicates.
            rem_size:    The number of components to remove.
            remove_ids:     The IDs of the components to remove.

        Args:
            entity:         The entity to modify.
            add_components: The components to add.

        Raises:
            Error: when called for a removed (and potentially recycled) entity.
            Error: when called with components that can't be added because they are already present.
            Error: when called with components that can't be removed because they are not present.
            Error: when called on a locked world. Do not use during [.World.query] iteration.
        """
        with Zone(
            function_name=(
                "World._remove_and_add[*Ts: ComponentType, rem_size: Int,"
                " remove_ids: InlineArray[ComponentId, rem_size]](entity:"
                " Entity, var *add_components: *Ts)"
            )
        ):
            comptime assert Self.component_manager._ContainsComponents[
                *Ts
            ], "One or more component types not in component manager"
            comptime assert constrain_components_unique[
                *Ts
            ](), "Duplicate component types in remove are not allowed."

            comptime add_size = len(Ts)
            comptime add_ids = Self.component_manager.get_id_arr[*Ts]()

            self._assert_unlocked()
            self._assert_alive(entity)

            # Reserve space for the possibility that a new archetype gets created
            # This ensure that no further allocations can happen in this function and
            # therefore all pointers to the current memory space stay valid!
            self._archetypes.reserve(len(self._archetypes) + 1)

            entity_loc = self._entities[entity.get_id()]

            old_archetype_idx = entity_loc.archetype_index
            ref old_archetype = self._archetypes.unsafe_get(old_archetype_idx)
            old_archetype_mask = old_archetype.get_mask()

            comptime if rem_size:
                if not old_archetype_mask.contains(BitMask(remove_ids)):
                    raise LarecsError(
                        ComponentError.missing_components_on_remove.with_components(
                            old_archetype_mask ^ BitMask(remove_ids)
                        )
                    )

            comptime if add_size:
                compare_mask = old_archetype_mask

                comptime if rem_size:
                    compare_mask.set(remove_ids, False)
                if compare_mask.contains(BitMask(add_ids)):
                    raise LarecsError(
                        ComponentError.existing_components_on_add.with_components(
                            compare_mask & BitMask(add_ids)
                        )
                    )

            comptime ComponentIdsType = InlineArray[
                ComponentId, add_size + rem_size
            ]
            comptime assert 0 <= add_size + rem_size

            comptime if add_size and rem_size:
                comptime concatenated = concatenate_inline_arrays(
                    remove_ids, add_ids
                )
                component_ids = concatenated
            elif Bool(add_size) and not rem_size:
                component_ids = rebind[ComponentIdsType](add_ids)
            elif not add_size and Bool(rem_size):
                component_ids = rebind[ComponentIdsType](remove_ids)
            else:
                return

            index_in_old_archetype = entity_loc.entity_index
            new_archetype_idx = self._get_archetype_index(
                component_ids, old_archetype.get_node_index()
            )
            ref old_archetype = self._archetypes.unsafe_get(old_archetype_idx)
            ref new_archetype = self._archetypes.unsafe_get(new_archetype_idx)
            index_in_new_archetype = new_archetype.add_entity(entity)

            # Move component data from old archetype to new archetype.
            comptime for id in range(Self.component_manager.component_count):
                comptime T = Self.component_types[id]
                if not old_archetype.has_components[T]():
                    continue

                comptime if rem_size:
                    if not new_archetype.has_components[T]():
                        continue

                new_archetype.set_components[T](
                    index_in_new_archetype,
                    old_archetype.get_component[T](
                        index_in_old_archetype
                    ).copy(),
                )

            new_archetype.init_components[*Ts](
                index_in_new_archetype, *add_components^
            )

            swapped = old_archetype.remove(index_in_old_archetype)
            if swapped:
                var swap_entity = old_archetype.get_entity(
                    entity_loc.entity_index
                )
                self._entities[
                    swap_entity.get_id()
                ].entity_index = entity_loc.entity_index

            self._entities[entity.get_id()] = EntityLocation(
                index_in_new_archetype, new_archetype_idx
            )

    @always_inline
    def _batch_remove_and_add[
        *Ts: ComponentType,
        rem_size: Int = 0,
        remove_ids: InlineArray[ComponentId, rem_size] = [],
        has_without_mask: Bool = False,
    ](
        mut self,
        query: QueryInfo[has_without_mask=has_without_mask],
        var *add_components: *Ts,
        out iterator: Self.Iterator[
            origin_of(self._archetypes),
            origin_of(self._locks),
            has_start_indices=True,
        ],
    ) raises LarecsError:
        """
        Adds and removes components to multiple [..entity.Entity Entities] specified by a [..query.QueryInfo].

        Parameters:
            Ts:                 The types of the components to add. Constraints: Must be in the component manager and contain no duplicates.
            rem_size:           The number of components to remove.
            remove_ids:         The IDs of the components to remove.
            has_without_mask:   Whether the query has a without mask.

        Args:
            query:          The query to determine which entities to modify.
            add_components: The components to add.

        Returns:
            An iterator over the modified entities.

        Raises:
            LarecsError: when called with a query that could match existing entities that already have at least one of the
                components to add.
            LarecsError: when called with a query that could match entities that don't have all of the components to remove.
            LarecsError: when called on a locked world. Do not use during [.World.query] iteration.
        """
        with Zone(
            function_name=(
                "World._batch_remove_and_add[*Ts: ComponentType, rem_size: Int,"
                " remove_ids: InlineArray[ComponentId, rem_size],"
                " has_without_mask: Bool](query: QueryInfo, var"
                " *add_components: *Ts, out iterator: Self.Iterator)"
            )
        ):
            comptime assert Self.component_manager._ContainsComponents[
                *Ts
            ], "One or more component types not in component manager"
            comptime assert constrain_components_unique[
                *Ts
            ](), "Duplicate component types in add are not allowed."

            comptime add_size = len(Ts)
            comptime add_ids = Self.component_manager.get_id_arr[*Ts]()

            comptime ComponentIdsType = InlineArray[
                ComponentId, add_size + rem_size
            ]
            comptime assert 0 <= add_size + rem_size

            # Note:
            #    This operation can never map multiple archetypes onto one, due to the requirement that components to add
            #    must be excluded in the query. Therefore, we can apply the transformation to each matching archetype
            #    individually without checking for edge cases where multiple archetypes get merged into one.
            #    This also enables potential parallelization optimizations.

            comptime if add_size:
                # If query could match archetypes that already have at least one of the components, raise an error
                # FIXME: When https://github.com/modular/modular/issues/5347 is fixed, we can use short-circuiting here.

                var strict_check_needed: Bool

                comptime if has_without_mask:
                    strict_check_needed = not query.without_mask[].contains(
                        BitMask(add_ids)
                    )
                else:
                    strict_check_needed = True

                if strict_check_needed:
                    for archetype in self._get_archetype_iterator(
                        query.mask, query.without_mask
                    ):
                        archetype_mask = archetype.get_mask()

                        comptime if rem_size:
                            archetype_mask.set(remove_ids, False)

                        if archetype and archetype_mask.contains_any(
                            BitMask(add_ids)
                        ):
                            raise LarecsError(
                                ComponentError.existing_components_on_add_query.with_components(
                                    archetype_mask & BitMask(add_ids)
                                )
                            )

            comptime if rem_size:
                # If query could match archetypes that don't have all of the components, raise an error
                if not query.mask.contains(BitMask(remove_ids)):
                    raise LarecsError(
                        ComponentError.missing_components_on_remove_query.with_components(
                            query.mask ^ BitMask(remove_ids)
                        )
                    )

                comptime if has_without_mask:
                    if query.without_mask[].contains_any(BitMask(remove_ids)):
                        raise LarecsError(
                            ComponentError.missing_components_on_remove_query.with_components(
                                query.without_mask[] & BitMask(remove_ids)
                            )
                        )

            comptime if add_size and rem_size:
                comptime concatenated = concatenate_inline_arrays(
                    remove_ids, add_ids
                )
                component_ids = concatenated
            elif Bool(add_size) and not rem_size:
                component_ids = rebind[ComponentIdsType](add_ids)
            elif not add_size and Bool(rem_size):
                component_ids = rebind[ComponentIdsType](remove_ids)
            else:
                # Nothing to do. Just return empty iterator.
                try:
                    iterator = {
                        Self.ArchetypeIterator(
                            Pointer(to=self._archetypes), List[Int]()
                        ),
                        Pointer(to=self._locks),
                        List[Int](),
                    }
                except _:
                    raise LarecsError(WorldError.out_of_locks)
                return

            self._assert_unlocked()

            comptime _2kb_of_UInt_or_Int = (1024 * 2) // size_of[UInt]()
            arch_start_idcs = List[Int](
                capacity=min(len(self._archetypes), _2kb_of_UInt_or_Int)
            )
            changed_archetype_idcs = List[Int](
                capacity=min(len(self._archetypes), _2kb_of_UInt_or_Int)
            )

            # Search for the archetype that matches the query mask
            with self._locked():
                for ref old_archetype1 in self._get_archetype_iterator(
                    query.mask, query.without_mask
                ):
                    # Two cases per matching archetype A:
                    # 1. If an archetype B with the new component combination exists, move entities from A to B
                    #    and insert new component data for moved entities.
                    # 2. If an archetype with the new component combination does not exist yet,
                    #    create new archetype B = A.different_by(component_ids) and move entities and component data from A to B.
                    old_node_index = old_archetype1.get_node_index()
                    new_archetype_idx = self._get_archetype_index[
                        add_size + rem_size
                    ](component_ids, old_node_index)

                    # We need to update the pointer to the old archetype, because the `self._archetypes` list may have been
                    # resized during the call to `_get_archetype_index`.
                    old_archetype_idx = self._archetype_map[old_node_index]
                    ref old_archetype = self._archetypes.unsafe_get(
                        index(old_archetype_idx)
                    )

                    ref new_archetype = self._archetypes.unsafe_get(
                        new_archetype_idx
                    )

                    # TODO: Optimization: If `new_archetype` is empty we can just shallow-copy the _ComponentStorage of `old_archetype` to `new_archetype` and reinit `old_archetype`.

                    old_archetype_size = len(old_archetype)
                    if old_archetype_idx == new_archetype_idx:
                        arch_start_idcs.append(0)
                        changed_archetype_idcs.append(new_archetype_idx)

                        comptime for i in range(add_size):
                            comptime T = Ts[i]
                            new_archetype.set_component_range[T](
                                0,
                                old_archetype_size,
                                add_components[i].copy(),
                            )
                        continue

                    old_archetype_unsafe = UnsafePointer(
                        to=old_archetype
                    ).as_unsafe_any_origin()
                    arch_start_idx = new_archetype.extend_from_archetype_unsafe(
                        old_archetype_unsafe, old_archetype_size
                    )
                    arch_start_idcs.append(arch_start_idx)
                    changed_archetype_idcs.append(new_archetype_idx)

                    comptime for i in range(add_size):
                        comptime T = Ts[i]
                        new_archetype.set_component_range[T](
                            arch_start_idx,
                            old_archetype_size,
                            add_components[i].copy(),
                        )

                    # Update entity index mappings for the moved entity range.
                    for entity_idx in range(old_archetype_size):
                        entity = old_archetype.get_entity(entity_idx)
                        self._entities[entity.get_id()] = EntityLocation(
                            arch_start_idx + entity_idx, new_archetype_idx
                        )

                    old_archetype.clear()

            # Return iterator to iterate over the changed entities.
            try:
                iterator = {
                    Self.ArchetypeIterator(
                        Pointer(to=self._archetypes), changed_archetype_idcs^
                    ),
                    Pointer(to=self._locks),
                    arch_start_idcs^,
                }
            except _:
                raise LarecsError(WorldError.out_of_locks)

    @always_inline
    def _assert_unlocked(self) raises LarecsError:
        """
        Checks if the world is locked, and raises if so.

        Raises:
            Error: If the world is locked.
        """
        with Zone(function_name="World._assert_unlocked()"):
            if self.is_locked():
                raise LarecsError(WorldError.world_is_locked)

    @always_inline
    def _assert_alive(self, entity: Entity) raises LarecsError:
        """
        Checks if the entity is alive, and raises if not.

        Args:
            entity: The entity to check.

        Raises:
            Error: If the entity does not exist.
        """
        with Zone(function_name="World._assert_alive(entity: Entity)"):
            if not self._entity_pool.is_alive(entity):
                raise LarecsError(
                    EntityError.non_existent_entity.with_entities(entity)
                )

    @always_inline
    def apply[
        OperationType: def[origin: MutOrigin](
            accessor: MutableEntityAccessor[origin, *Self.component_types]
        ) raises -> None,
        //,
        has_without_mask: Bool = False,
        *,
        unroll_factor: Int = 1,
    ](
        mut self,
        query: QueryInfo[has_without_mask=has_without_mask],
        operation: OperationType,
    ) raises LarecsError:
        """
        Applies an operation to all entities with the given components.

        Parameters:
            OperationType: The type of the operation to apply.
            has_without_mask: Whether the query has a without mask.
            unroll_factor: The unroll factor for the operation
                (see [vectorize doc](https://docs.modular.com/mojo/stdlib/algorithm/functional/vectorize)).

        Args:
            query: The query to determine which entities to apply the operation to.
            operation: The operation to apply.

        Raises:
            Error: If the world is locked.
            Error: If the operation raises.
        """

        with Zone(
            function_name=(
                "World.apply[OperationType, has_without_mask: Bool, *,"
                " unroll_factor: Int](query: QueryInfo, operation:"
                " OperationType)"
            )
        ):
            self._assert_unlocked()

            with self._locked():
                for ref archetype in Self.ArchetypeIterator(
                    Pointer(to=self._archetypes),
                    query.copy(),
                ):
                    for i in range(len(archetype)):
                        try:
                            ref entity = archetype.get_entity_accessor(i)
                            operation(entity)
                        except:
                            raise LarecsError(UnknownError())

    # def apply[
    #     OperationType: def[simd_width: Int](
    #         accessor: MutableEntityAccessor
    #     ) raises -> None,
    #     //,
    #     has_without_mask: Bool = False,
    #     *,
    #     simd_width: Int = 1,
    #     unroll_factor: Int = 1,
    # ](
    #     mut self,
    #     query: QueryInfo[has_without_mask=has_without_mask],
    #     operation: OperationType,
    # ) raises LarecsError:
    #     """
    #     Applies an operation to all entities with the given components.

    #     The operation is applied to chunks of `simd_width` entities,
    #     unless not enough are available anymore. Then the chunk size
    #     `simd_width` is reduced.

    #     Processes full `simd_width` chunks directly, then handles any trailing
    #     entities one at a time.

    #     Caution! If `simd_width` is greater than 1, the operation **must**
    #     apply to the `simd_width` elements after the element passed to
    #     `operation`, assuming that each component is stored in contiguous
    #     memory. This may require knowledge of the memory layout
    #     of the components!

    #     Parameters:
    #         OperationType: The type of the operation to apply.
    #         has_without_mask: Whether the query has a without mask.
    #         simd_width: The SIMD width for the operation
    #             (see [vectorize doc](https://docs.modular.com/mojo/stdlib/algorithm/backend/vectorize/vectorize)).
    #         unroll_factor: The unroll factor for the operation
    #             (see [vectorize doc](https://docs.modular.com/mojo/stdlib/algorithm/backend/vectorize/vectorize)).

    #     Args:
    #         query: The query to determine which entities to apply the operation to.
    #         operation: The operation to apply.

    #     Constraints:
    #         The simd_width must be a power of 2.

    #     Raises:
    #         LarecsError: If the world is locked.

    #     Example:
    #     ```mojo {doctest="apply" global=true hide=true}
    #     from larecs import World, MutableEntityAccessor
    #     ```

    #     ```mojo {doctest="apply"}
    #     from sys.info import simdwidthof
    #     from memory import LegacyUnsafePointer

    #     world = World[Float64]()
    #     e = world.add_entity()

    #     def operation[simd_width: Int](accessor: MutableEntityAccessor) capturing:
    #         # Define the operation to apply here.
    #         # Note that due to the immature
    #         # capturing system of Mojo, the world may be
    #         # accessible by copy capturing here, even
    #         # though it is not copyable.
    #         # Do NOT change `world` from inside the operation,
    #         # as it will not be reflected in the world
    #         # or may cause a segmentation fault.

    #         try:
    #             # Get the component
    #             ref component = accessor.get[Float64]()

    #             # Get an unsafe pointer to the memory
    #             # location of the component
    #             ptr = LegacyUnsafePointer(to=component)
    #         except:
    #             return

    #         # Load a SIMD of size `simd_width`
    #         # Note that a strided load is needed if the component as more than one field.
    #         val = ptr.load[width=simd_width]()

    #         # Do an operation on the SIMD
    #         val += 1

    #         # Store the SIMD at the same address
    #         ptr.store(val)

    #     world.apply[operation, simd_width=simdwidthof[Float64]()](world.query[Float64]())
    #     ```

    #     """
    #     with TraceGuard(name="World.apply simd"):
    #         self._assert_unlocked()

    #         with self._locked():
    #             for archetype in Self.ArchetypeIterator(
    #                 Pointer(to=self._archetypes),
    #                 query.copy(),
    #             ):

    #                 @always_inline
    #                 def closure[width: Int](i: Int) {read}:
    #                     accessor = archetype[].get_entity_accessor(i)
    #                     try:
    #                         operation[width](accessor)
    #                     except:
    #                         # TODO: Silence all errors at the moment. In the future this should be handled more gracefully, e.g. by collecting errors and returning them after the loop.
    #                         pass

    #                 vectorize[simd_width, unroll_factor=unroll_factor](
    #                     len(archetype[]), closure
    #                 )

    # def Reset(self):
    #     """
    #     Reset removes all _entities and _resources from the world.

    #     Does NOT free reserved memory, remove _archetypes, clear the _registry, clear cached filters, etc.
    #     However, it removes _archetypes with a relation component that is not zero.

    #     Can be used to run systematic simulations without the need to re-allocate memory for each run.
    #     Accelerates re-populating the world by a factor of 2-3.
    #     """
    #     self._assert_unlocked()

    #     self._entities = self._entities[:1]
    #     self._tarquery.Reset()
    #     self._entity_pool.Reset()
    #     self._locks.Reset()
    #     self._resources.reset()

    #     var len = self._nodes.Len()
    #     var i: int32
    #     for i = 0 in range(i < len, i++):
    #         self._nodes.get(i).Reset(self.Cache())

    # def Query(self, filter: Filter) -> Query:
    #     """
    #     Query creates a [Query] iterator.

    #     Locks the world to prevent changes to component compositions.
    #     The lock is released automatically when the query finishes iteration, or when [Query.Close] is called.
    #     The number of simultaneous _locks (and thus open queries) at a given time is limited to [MaskTotalBits] (256).

    #     A query can iterate through its _entities only once, and can't be used anymore afterwards.

    #     To create a [Filter] for querying, see [All], [Mask.Without], [Mask.Exclusive] and [RelationFilter].

    #     For type-safe generics queries, see package [github.com/mlange-42/arche/generic].
    #     For advanced filtering, see package [github.com/mlange-42/arche/filter].
    #     """
    #     var l = self.lock()
    #     if cached, var ok = filter.(*CachedFilter); ok:
    #         return newCachedQuery(self, cached.filter, l, self._filter_cache.get(cached).Archetypes.pointers)

    #     return newQuery(self, filter, l, self._node_pointers)

    # def Resources(self):
    #     """
    #     Resources of the world.

    #     Resources are component-like data that is not associated to an entity, but unique to the world.
    #     """
    #     return &self._resources

    # def Cache(self):
    #     """
    #     Cache returns the [Cache] of the world, for registering filters.

    #     See [Cache] for details on filter caching.
    #     """
    #     if self._filter_cache.getArchetypes == nil:
    #         self._filter_cache.getArchetypes = self.getArchetypes

    #     return &self._filter_cache

    # def Batch(self):
    #     """
    #     Batch creates a [Batch] processing helper.
    #     It provides the functionality to manipulate large numbers of _entities in batches,
    #     which is more efficient than handling them one by one.
    #     """
    #     return &Batchw

    @always_inline
    def query[
        *Ts: ComponentType
    ](
        mut self,
        out iterator: Self.Query[
            origin_of(self._archetypes),
            origin_of(self._locks),
            has_without_mask=False,
        ],
    ):
        """
        Returns an [..query.Query] for all [..entity.Entity Entities] with the given components.

        Parameters:
            Ts: The types of the components.

        Returns:
            A [..query.Query] for all entities with the given components.
        """
        with Zone(
            function_name=(
                "World.query[*Ts: ComponentType](out iterator: Self.Query)"
            )
        ):
            comptime assert constrain_components_unique[
                *Ts
            ](), "Duplicate component types in query are not allowed."
            comptime component_count = len(Ts)

            var bitmask: BitMask

            comptime if not component_count:
                bitmask = BitMask()
            else:
                bitmask = BitMask(Self.component_manager.get_id_arr[*Ts]())

            iterator = Self.Query[has_without_mask=False](
                Pointer(to=self._archetypes), Pointer(to=self._locks), bitmask
            )

    def _get_entity_iterator[
        has_without_mask: Bool = False, has_start_indices: Bool = False
    ](
        mut self,
        mask: BitMask,
        without_mask: StaticOptional[BitMask, has_without_mask],
        var start_indices: StaticOptional[List[Int], has_start_indices] = None,
        out iterator: Self.Iterator[
            origin_of(self._archetypes),
            origin_of(self._locks),
            has_start_indices=has_start_indices,
        ],
    ) raises LarecsError:
        """
        Creates an iterator over all [..entity.Entity Entities] that have / do not have the components in the provided masks.

        Parameters:
            has_without_mask: Whether a without_mask is provided.
            has_start_indices: Whether start_indices are provided.


        Args:
            mask:          The mask of components to include.
            without_mask:  The mask of components to exclude.
            start_indices: The start indices of the iterator. See [..query._WorldEntityIterator].
        """
        with Zone(
            function_name=(
                "World._get_entity_iterator[has_without_mask: Bool,"
                " has_start_indices: Bool](mask: BitMask, without_mask:"
                " StaticOptional[BitMask, has_without_mask], var start_indices:"
                " StaticOptional[List[Int], has_start_indices], out iterator:"
                " Self.Iterator)"
            )
        ):
            try:
                iterator = Self.Iterator[
                    origin_of(self._archetypes),
                    origin_of(self._locks),
                    has_start_indices=has_start_indices,
                ](
                    Pointer(to=self._archetypes),
                    QueryInfo(
                        mask,
                        without_mask.copy(),
                    ),
                    Pointer(to=self._locks),
                    start_indices^,
                )
            except _:
                raise LarecsError(UnknownError())

    @always_inline
    def _get_archetype_iterator[
        has_without_mask: Bool = False
    ](
        ref self,
        mask: BitMask,
        without_mask: StaticOptional[BitMask, has_without_mask] = None,
        out iterator: Self.ArchetypeIterator[
            origin_of(self._archetypes), has_without_mask=has_without_mask
        ],
    ):
        """
        Creates an iterator over all archetypes that match the query.

        Returns:
            An iterator over all archetypes that match the query.
        """
        with Zone(
            function_name=(
                "World._get_archetype_iterator[has_without_mask: Bool](mask:"
                " BitMask, without_mask: StaticOptional[BitMask,"
                " has_without_mask], out iterator: Self.ArchetypeIterator)"
            )
        ):
            iterator = Self.ArchetypeIterator(
                Pointer(to=self._archetypes),
                QueryInfo(
                    mask,
                    without_mask.copy(),
                ),
            )

    @always_inline
    def is_locked(self, out result: Bool):
        """
        Returns whether the world is locked by any [.World.query queries].
        """
        with Zone(function_name="World.is_locked(out result: Bool)"):
            return self._locks.is_locked()

    @always_inline
    def _lock(mut self, out lock: Int) raises LarecsError:
        """
        Locks the world and gets the lock bit for later unlocking.

        Returns:
            The lock bit for later unlocking.

        Raises:
            LarecsError: when the world is already locked by the maximum number of locks (256 in the current implementation).
        """
        with Zone(function_name="World._lock(out lock: Int)"):
            try:
                return self._locks.lock()
            except:
                raise LarecsError(WorldError.out_of_locks)

    @always_inline
    def _unlock(mut self, lock: Int):
        """
        Unlocks the given lock bit.

        Args:
            lock: The lock bit to unlock.
        """
        with Zone(function_name="World._unlock(lock: Int)"):
            try:
                self._locks.unlock(lock)
            except e:
                # This should crash the program because an unexpected internal error occurred
                assert False, "unlock failed: " + String(e)

    @always_inline
    def _locked(
        mut self,
    ) -> LockedContext[origin_of(self._locks)]:
        """
        Returns a context manager that unlocks the world when it goes out of scope.

        Returns:
            A context manager that unlocks the world when it goes out of scope.
        """
        with Zone(function_name="World._locked()"):
            return LockedContext(Pointer(to=self._locks))

        # def Mask(self, entity: Entity) -> Mask:
        #     """
        #     Mask returns the archetype [Mask] for the given [Entity].
        #     """
        #     if !self._entity_pool.Alive(entity):
        #         panic("can't get mask for a dead entity")

        #     return self._entities[entity.id].arch.Mask

        # def Ids(self, entity: Entity):
        #     """
        #     Ids returns the component IDs for the archetype of the given [Entity].

        #     Returns a copy of the archetype's component IDs slice, for safety.
        #     This means that the result can be manipulated safely,
        #     but also that calling the method may incur some significant cost.
        #     """
        #     if !self._entity_pool.Alive(entity):
        #         panic("can't get component IDs for a dead entity")

        #     return append([]Id, self._entities[entity.id].arch.node.Ids...)

        # def SetListener(self, _listener: Listener):
        #     """
        #     SetListener sets a [Listener] for the world.
        #     The _listener is immediately called on every [ecs.Entity] change.
        #     Replaces the current _listener. Call with nil to remove a _listener.

        #     For details, see [EntityEvent], [Listener] and sub-package [event].
        #     """
        #     self._listener = _listener

        # def Stats(self):
        #     """
        #     Stats reports statistics for inspecting the World.

        #     The underlying [_stats.World] object is re-used and updated between calls.
        #     The returned pointer should thus not be stored for later analysis.
        #     Rather, the required data should be extracted immediately.
        #     """
        #     self._stats.Entities = _stats.Entities
        #         Used:     self._entity_pool.Len(),
        #         Total:    self._entity_pool.Cap(),
        #         Recycled: self._entity_pool.Available(),
        #         Capacity: self._entity_pool.TotalCap(),

        #     var compCount = len(self._registry.Components)
        #     var types = append([]reflect.Type, self._registry.Types[:compCount]...)

        #     var memory = cap(self._entities)*int(entityIndexSize) + self._entity_pool.TotalCap()*int(entitySize)

        #     var cntOld = int32(len(self._stats.Nodes))
        #     var cntNew = int32(self._nodes.Len())
        #     var cntActive = 0
        #     var i: int32
        #     for i = 0 in range(i < cntOld, i++):
        #         var node = self._nodes.get(i)
        #         var nodeStats = &self._stats.Nodes[i]
        #         node.UpdateStats(nodeStats, &self._registry)
        #         if node.IsActive:
        #             memory += nodeStats.Memory
        #             cntActive++

        #     for i = cntOld in range(i < cntNew, i++):
        #         var node = self._nodes.get(i)
        #         self._stats.Nodes = append(self._stats.Nodes, node.Stats(&self._registry))
        #         if node.IsActive:
        #             memory += self._stats.Nodes[i].Memory
        #             cntActive++

        #     self._stats.ComponentCount = compCount
        #     self._stats.ComponentTypes = types
        #     self._stats.Locked = self.is_locked()
        #     self._stats.Memory = memory
        #     self._stats.CachedFilters = len(self._filter_cache.filters)
        #     self._stats.ActiveNodeCount = cntActive

        #     return &self._stats

        # def DumpEntities(self) -> EntityDump:
        #     """
        #     DumpEntities dumps entity information into an [EntityDump] object.
        #     This dump can be used with [World.LoadEntities] to set the World's entity state.

        #     For world serialization with components and _resources, see module [github.com/mlange-42/arche-serde].
        #     """
        #     var alive = []uint32

        #     var query = self.Query(All())
        #     for query.Next()
        #         alive = append(alive, uint32(query.Entity().id))

        #     var data = EntityDump
        #         Entities:  append([]Entity, self._entity_pool._entities...),
        #         Alive:     alive,
        #         Next:      uint32(self._entity_pool.next),
        #         Available: self._entity_pool.available,

        #     return data

        # def LoadEntities(self, data: *EntityDump):
        #     """
        #     LoadEntities resets all _entities to the state saved with [World.DumpEntities].

        #     Use this only on an empty world! Can be used after [World.Reset].

        #     The resulting world will have the same _entities (in terms of Id, generation and alive state)
        #     as the original world. This is necessary for proper serialization of entity relations.
        #     However, the _entities will not have any components.

        #     Panics if the world has any dead or alive _entities.

        #     For world serialization with components and _resources, see module [github.com/mlange-42/arche-serde].
        #     """
        #     self._assert_unlocked()

        #     if len(self._entity_pool._entities) > 1 || self._entity_pool.available > 0:
        #         panic("can set entity data only on a fresh or reset world")

        #     var capacity = capacity(len(data.Entities), self.config.CapacityIncrement)

        #     var _entities = make([]Entity, 0, capacity)
        #     _entities = append(_entities, data.Entities...)

        #     self._entity_pool._entities = _entities
        #     self._entity_pool.next = eid(data.Next)
        #     self._entity_pool.available = data.Available

        #     self._entities = make([]entityIndex, len(data.Entities), capacity)
        #     self._tarquery = bitSet
        #     self._tarquery.ExtendTo(capacity)

        #     var arch = self._archetypes.get(0)
        #     for _, idx in enumerate(data.Alive):
        #         var entity = self._entity_pool._entities[idx]
        #         var archIdx = arch.Alloc(entity)
        #         self._entities[entity.id] = entityIndexarch: arch, index: archIdx

        # ----------------- from world_internal.go -----------------

        # def newEntities(self, count: int, targetID: ID, hasTarget: Bool, target: Entity, comps: ...ID):
        #     """
        #     Creates new _entities without returning a query over them.
        #     Used via [World.Batch].
        #     """
        #     arch, var startIdx = self.newEntitiesNoNotify(count, targetID, hasTarget, target, comps...)

        #     if self._listener != nil:
        #         var newRel *ID
        #         if arch.HasRelationComponent:
        #             newRel = &arch.RelationComponent

        #         var bits = subscription(true, false, len(comps) > 0, false, newRel != nil, newRel != nil)
        #         var trigger = self._listener.Subscriptions() & bits
        #         if trigger != 0 && subscribes(trigger, &arch.Mask, nil, self._listener.Components(), nil, newRel):
        #             var cnt = uint32(count)
        #             var i: uint32
        #             for i = 0 in range(i < cnt, i++):
        #                 var idx = startIdx + i
        #                 var entity = arch.GetEntity(idx)
        #                 self._listener.Notify(self, EntityEventEntity: entity, Added: arch.Mask, AddedIDs: comps, NewRelation: newRel, EventTypes: bits)

        #     return arch, startIdx

        # def newEntitiesQuery(self, count: int, targetID: ID, hasTarget: Bool, target: Entity, comps: ...ID) -> Query:
        #     """
        #     Creates new _entities and returns a query over them.
        #     Used via [World.Batch].
        #     """
        #     arch, var startIdx = self.newEntitiesNoNotify(count, targetID, hasTarget, target, comps...)
        #     var lock = self.lock()

        #     var batches = batchArchetypes
        #         Added:   arch.Components(),
        #         Removed: nil,

        #     batches.Add(arch, nil, startIdx, arch.Len())
        #     return newBatchQuery(self, lock, &batches)

        # def newEntitiesWith(self, count: int, targetID: ID, hasTarget: Bool, target: Entity, comps: ...Component):
        #     """
        #     Creates new _entities with component values without returning a query over them.
        #     Used via [World.Batch].
        #     """
        #     var ids = make([]ID, len(comps))
        #     for i, c in enumerate(comps):
        #         ids[i] = c.ID

        #     arch, var startIdx = self.newEntitiesWithNoNotify(count, targetID, hasTarget, target, ids, comps...)

        #     if self._listener != nil:
        #         var newRel *ID
        #         if arch.HasRelationComponent:
        #             newRel = &arch.RelationComponent

        #         var bits = subscription(true, false, len(comps) > 0, false, newRel != nil, newRel != nil)
        #         var trigger = self._listener.Subscriptions() & bits
        #         if trigger != 0 && subscribes(trigger, &arch.Mask, nil, self._listener.Components(), nil, newRel):
        #             var i: uint32
        #             var cnt = uint32(count)
        #             for i = 0 in range(i < cnt, i++):
        #                 var idx = startIdx + i
        #                 var entity = arch.GetEntity(idx)
        #                 self._listener.Notify(self, EntityEventEntity: entity, Added: arch.Mask, AddedIDs: ids, NewRelation: newRel, EventTypes: bits)

        #     return arch, startIdx

        # def newEntitiesWithQuery(self, count: int, targetID: ID, hasTarget: Bool, target: Entity, comps: ...Component) -> Query:
        #     """
        #     Creates new _entities with component values and returns a query over them.
        #     Used via [World.Batch].
        #     """
        #     var ids = make([]ID, len(comps))
        #     for i, c in enumerate(comps):
        #         ids[i] = c.ID

        #     arch, var startIdx = self.newEntitiesWithNoNotify(count, targetID, hasTarget, target, ids, comps...)
        #     var lock = self.lock()
        #     var batches = batchArchetypes
        #         Added:   arch.Components(),
        #         Removed: nil,

        #     batches.Add(arch, nil, startIdx, arch.Len())
        #     return newBatchQuery(self, lock, &batches)

        # def newEntitiesNoNotify(self, count: int, targetID: ID, hasTarget: Bool, target: Entity, comps: ...ID):
        #     """
        #     Internal method to create new _entities.
        #     """
        #     self.checkLocked()

        #     if count < 1:
        #         panic("can only create a positive number of _entities")

        #     if !target.IsZero() && !self.entityPool.Alive(target):
        #         panic("can't make a dead entity a relation target")

        #     var arch = self._archetypes.Get(0)
        #     if len(comps) > 0:
        #         arch = self._find_or_create_archetype(arch, comps, nil, target)

        #     if hasTarget:
        #         self.checkRelation(arch, targetID)
        #         if !target.IsZero():
        #             self._tarquery.Set(target.id, true)

        #     var startIdx = arch.Len()
        #     self.createEntities(arch, uint32(count))

        #     return arch, startIdx

        # def newEntitiesWithNoNotify(self, count: int, targetID: ID, hasTarget: Bool, target: Entity, ids: []ID, comps: ...Component):
        #     """
        #     Internal method to create new _entities with component values.
        #     """
        #     self.checkLocked()

        #     if count < 1:
        #         panic("can only create a positive number of _entities")

        #     if !target.IsZero() && !self.entityPool.Alive(target):
        #         panic("can't make a dead entity a relation target")

        #     if len(comps) == 0:
        #         return self.newEntitiesNoNotify(count, targetID, hasTarget, target)

        #     var cnt = uint32(count)

        #     var arch = self._archetypes.Get(0)
        #     if len(comps) > 0:
        #         arch = self._find_or_create_archetype(arch, ids, nil, target)

        #     if hasTarget:
        #         self.checkRelation(arch, targetID)
        #         if !target.IsZero():
        #             self._tarquery.Set(target.id, true)

        #     var startIdx = arch.Len()
        #     self.createEntities(arch, uint32(count))

        #     var i: uint32
        #     for i = 0 in range(i < cnt, i++):
        #         var idx = startIdx + i
        #         var entity = arch.GetEntity(idx)
        #         for _, c in enumerate(comps):
        #             self.copyTo(entity, c.ID, c.Comp)

        #     return arch, startIdx

        # def removeEntities(self, filter: Filter) -> int:
        #     """
        #     RemoveEntities removes and recycles all _entities matching a filter.

        #     Returns the number of removed _entities.

        #     Panics when called on a locked world.
        #     Do not use during [Query] iteration!
        #     """
        #     self.checkLocked()

        #     var lock = self.lock()

        #     var bits: event.Subscription
        #     var listen: Bool

        #     var count: uint32

        #     var arches = self.getArchetypes(filter)
        #     var numArches = int32(len(arches))
        #     var i: int32
        #     for i = 0 in range(i < numArches, i++):
        #         var arch = arches[i]
        #         var ln = arch.Len()
        #         if ln == 0:
        #             continue

        #         count += ln

        #         var oldRel *ID
        #         var oldIds []ID
        #         if self._listener != nil:
        #             if arch.HasRelationComponent:
        #                 oldRel = &arch.RelationComponent

        #             if len(arch.node.Ids) > 0:
        #                 oldIds = arch.node.Ids

        #             bits = subscription(false, true, false, len(oldIds) > 0, oldRel != nil, oldRel != nil)
        #             var trigger = self._listener.Subscriptions() & bits
        #             listen = trigger != 0 && subscribes(trigger, nil, &arch.Mask, self._listener.Components(), oldRel, nil)

        #         var j: uint32
        #         for j = 0 in range(j < ln, j++):
        #             var entity = arch.GetEntity(j)
        #             if listen:
        #                 self._listener.Notify(self, EntityEventEntity: entity, Removed: arch.Mask, RemovedIDs: oldIds, OldRelation: oldRel, OldTarget: arch.RelationTarget, EventTypes: bits)

        #             var index = &self._entities[entity.id]
        #             index.arch = nil

        #             if self._tarquery.Get(entity.id):
        #                 self._cleanup_archetypes(entity)
        #                 self._tarquery.Set(entity.id, false)

        #             self.entityPool.Recycle(entity)

        #         arch.Reset()
        #         self._cleanup_archetype(arch)

        #     self.unlock(lock)

        #     return int(count)

        # def notifyExchange(self, arch: *archetype, old_mask: *Mask, entity: Entity, add: []ID, rem: []ID, oldTarget: Entity, oldRel: *ID):
        #     """
        #     notify listeners for an exchange.
        #     """
        #     var newRel *ID
        #     if arch.HasRelationComponent:
        #         newRel = &arch.RelationComponent

        #     var relChanged = false
        #     if oldRel != nil || newRel != nil:
        #         relChanged = (oldRel == nil) != (newRel == nil) || *oldRel != *newRel

        #     var targChanged = oldTarget != arch.RelationTarget

        #     var bits = subscription(false, false, len(add) > 0, len(rem) > 0, relChanged, relChanged || targChanged)
        #     var trigger = self._listener.Subscriptions() & bits
        #     if trigger != 0:
        #         var changed = old_mask.Xor(&arch.Mask)
        #         var added = arch.Mask.And(&changed)
        #         var removed = old_mask.And(&changed)
        #         if subscribes(trigger, &added, &removed, self._listener.Components(), oldRel, newRel):
        #             self._listener.Notify(self,
        #                 EntityEventEntity: entity, Added: added, Removed: removed,
        #                     AddedIDs: add, RemovedIDs: rem, OldRelation: oldRel, NewRelation: newRel,
        #                     OldTarget: oldTarget, EventTypes: bits,
        #             )

        # def exchangeBatch(self, filter: Filter, add: []ID, rem: []ID, relation: ID, hasRelation: Bool, target: Entity) -> int:
        #     """
        #     ExchangeBatch exchanges components for many _entities, matching a filter.

        #     If the callback argument is given, it is called with a [Query] over the affected _entities,
        #     one Query for each affected archetype.

        #     Panics:
        #     - when called with components that can't be added or removed because they are already present/not present, respectively.
        #     - when called on a locked world. Do not use during [Query] iteration!

        #     See also [World.Exchange].
        #     """
        #     var batches = batchArchetypes
        #         Added:   add,
        #         Removed: rem,

        #     var count = self.exchangeBatchNoNotify(filter, add, rem, relation, hasRelation, target, &batches)

        #     if self._listener != nil:
        #         self.notifyQuery(&batches)

        #     return count

        # def exchangeBatchQuery(self, filter: Filter, add: []ID, rem: []ID, relation: ID, hasRelation: Bool, target: Entity) -> Query:
        #     var batches = batchArchetypes
        #         Added:   add,
        #         Removed: rem,

        #     self.exchangeBatchNoNotify(filter, add, rem, relation, hasRelation, target, &batches)

        #     var lock = self.lock()
        #     return newBatchQuery(self, lock, &batches)

        # def exchangeBatchNoNotify(self, filter: Filter, add: []ID, rem: []ID, relation: ID, hasRelation: Bool, target: Entity, batches: *batchArchetypes) -> int:
        #     self.checkLocked()

        #     if len(add) == 0 && len(rem) == 0:
        #         if hasRelation:
        #             panic("exchange operation has no effect, but a relation is specified. Use Batch.SetRelation instead")

        #         return 0

        #     var arches = self.getArchetypes(filter)
        #     var lengths = make([]uint32, len(arches))
        #     var totalEntities: uint32 = 0
        #     for i, arch in enumerate(arches):
        #         lengths[i] = arch.Len()
        #         totalEntities += arch.Len()

        #     for i, arch in enumerate(arches):
        #         var archLen = lengths[i]

        #         if archLen == 0:
        #             continue

        #         newArch, var start = self.exchangeArch(arch, archLen, add, rem, relation, hasRelation, target)
        #         batches.Add(newArch, arch, start, newArch.Len())

        #     return int(totalEntities)

        # def exchangeArch(self, old_archetype: *archetype, oldArchLen: uint32, add: []ID, rem: []ID, relation: ID, hasRelation: Bool, target: Entity):
        #     var mask = self._get_exchange_mask(old_archetype.Mask, add, rem)
        #     var oldIDs = old_archetype.Components()

        #     if hasRelation:
        #         if !mask.Get(relation):
        #             tp, var _ = self._registry.ComponentType(relation.id)
        #             panic(fmt.Sprintf("can't add relation: resulting entity has no component %s", tp.Name()))

        #         if !self._registry.IsRelation.Get(relation):
        #             tp, var _ = self._registry.ComponentType(relation.id)
        #             panic(fmt.Sprintf("can't add relation: %s is not a relation component", tp.Name()))

        #     else
        #         target = old_archetype.RelationTarget
        #         if !target.IsZero() && old_archetype.Mask.ContainsAny(&self._registry.IsRelation):
        #             for _, id in enumerate(rem):
        #                 # Removing a relation
        #                 if self._registry.IsRelation.Get(id):
        #                     target = Entity
        #                     break

        #     var arch = self._find_or_create_archetype(old_archetype, add, rem, target)

        #     var startIdx = arch.Len()
        #     var count = oldArchLen
        #     arch.AllocN(uint32(count))

        #     var i: uint32
        #     for i = 0 in range(i < count, i++):
        #         var idx = startIdx + i
        #         var entity = old_archetype.GetEntity(i)
        #         var index = &self._entities[entity.id]
        #         arch.SetEntity(idx, entity)
        #         index.arch = arch
        #         index.index = idx

        #         for _, id in enumerate(oldIDs):
        #             if mask.Get(id):
        #                 var comp = old_archetype.Get(i, id)
        #                 arch.SetPointer(idx, id, comp)

        #     if !target.IsZero():
        #         self._tarquery.Set(target.id, true)

        #     # Theoretically, it could be oldArchLen < old_archetype.Len(),
        #     # which means we can't reset the archetype.
        #     # However, this should not be possible as processing an entity twice
        #     # would mean an illegal component addition/removal.
        #     old_archetype.Reset()
        #     self._cleanup_archetype(old_archetype)

        #     return arch, startIdx

        # def copyTo(self, entity: Entity, id: ID, comp: interface) -> unsafe:
        #     """
        #     Copies a component to an entity
        #     """
        #     if !self.Has(entity, id):
        #         panic("can't copy component into entity that has no such component type")

        #     var index = &self._entities[entity.id]
        #     var arch = index.arch

        #     return arch.Set(index.index, id, comp)

        # def getArchetypes(self, filter: Filter):
        #     """
        #     Returns all _archetypes that match the given filter.
        #     """
        #     if cached, var ok = filter.(*CachedFilter); ok:
        #         return self._filter_cache.get(cached).Archetypes.pointers

        #     var arches = []*archetype
        #     var _nodes = self._node_pointers

        #     for _, nd in enumerate(_nodes):
        #         if !nd.IsActive || !nd.Matches(filter):
        #             continue

        #         if rf, var ok = filter.(*RelationFilter); ok:
        #             var target = rf.Target
        #             if arch, var ok = nd.archetypeMap[target]; ok:
        #                 arches = append(arches, arch)

        #             continue

        #         var nodeArches = nd.Archetypes()
        #         var ln2 = int32(nodeArches.Len())
        #         var j: int32
        #         for j = 0 in range(j < ln2, j++):
        #             var a = nodeArches.Get(j)
        #             if a.IsActive():
        #                 arches = append(arches, a)

        #     return arches

        # def extendArchetypeLayouts(self, count: uint8):
        #     """
        #     Extend the number of access layouts in _archetypes.
        #     """
        #     var len = self._nodes.Len()
        #     var i: int32
        #     for i = 0 in range(i < len, i++):
        #         self._nodes.Get(i).ExtendArchetypeLayouts(count)

        # def componentID(self, tp: reflect.Type) -> ID:
        #     """
        #     componentID returns the ID for a component type, and registers it if not already registered.
        #     """
        #     id, var newID = self._registry.ComponentID(tp)
        #     if newID:
        #         if self.is_locked():
        #             self._registry.unregisterLastComponent()
        #             panic("attempt to register a new component in a locked world")

        #         if id > 0 && id%layoutChunkSize == 0:
        #             self.extendArchetypeLayouts(id + layoutChunkSize)

        #     return IDid: id

        # def resourceID(self, tp: reflect.Type) -> ResID:
        #     """
        #     resourceID returns the ID for a resource type, and registers it if not already registered.
        #     """
        #     id, var _ = self._resources._registry.ComponentID(tp)
        #     return ResIDid: id

        # def closeQuery(self, query: *Query):
        #     """
        #     closeQuery closes a query and unlocks the world.
        #     """
        #     query.nodeIndex = -2
        #     query.archIndex = -2
        #     self.unlock(query.lockBit)

        #     if self._listener != nil:
        #         if arch, var ok = query.nodeArchetypes.(*batchArchetypes); ok:
        #             self.notifyQuery(arch)

        # def notifyQuery(self, batchArch: *batchArchetypes):
        #     """
        #     notifies the _listener for all _entities on a batch query.
        #     """
        #     var count = batchArch.Len()
        #     var i: int32
        #     for i = 0 in range(i < count, i++):
        #         var arch = batchArch.Get(i)

        #         var newRel *ID
        #         if arch.HasRelationComponent:
        #             newRel = &arch.RelationComponent

        #         var event = EntityEvent
        #             Entity: Entity, Added: arch.Mask, Removed: Mask, AddedIDs: batchArch.Added, RemovedIDs: batchArch.Removed,
        #             OldRelation: nil, NewRelation: newRel,
        #             OldTarget: Entity, EventTypes: 0,

        #         var old_archetype = batchArch.OldArchetype[i]
        #         var relChanged = newRel != nil
        #         var targChanged = !arch.RelationTarget.IsZero()

        #         if old_archetype != nil:
        #             var oldRel *ID
        #             if old_archetype.HasRelationComponent:
        #                 oldRel = &old_archetype.RelationComponent

        #             relChanged = false
        #             if oldRel != nil || newRel != nil:
        #                 relChanged = (oldRel == nil) != (newRel == nil) || *oldRel != *newRel

        #             targChanged = old_archetype.RelationTarget != arch.RelationTarget
        #             var changed = event.Added.Xor(&old_archetype.node.Mask)
        #             event.Added = changed.And(&event.Added)
        #             event.Removed = changed.And(&old_archetype.node.Mask)
        #             event.OldTarget = old_archetype.RelationTarget
        #             event.OldRelation = oldRel

        #         var bits = subscription(old_archetype == nil, false, len(batchArch.Added) > 0, len(batchArch.Removed) > 0, relChanged, relChanged || targChanged)
        #         event.EventTypes = bits

        #         var trigger = self._listener.Subscriptions() & bits
        #         if trigger != 0 && subscribes(trigger, &event.Added, &event.Removed, self._listener.Components(), event.OldRelation, event.NewRelation):
        #             start, var end = batchArch.StartIndex[i], batchArch.EndIndex[i]
        #             var e: uint32
        #             for e = start in range(e < end, e++):
        #                 var entity = arch.GetEntity(e)
        #                 event.Entity = entity
        #                 self._listener.Notify(self, event)


@fieldwise_init
struct LockedContext[origin: MutOrigin](ImplicitlyCopyable):
    """
    A context manager for locking and unlocking the world.

    Parameters:
        origin: The origin of the LockManager to handle.
    """

    var _locks: Pointer[LockManager, Self.origin]
    """Pointer to the lock manager controlled by this context."""
    var _lock: Int
    """The lock bit acquired by this context."""

    @always_inline
    def __init__(out self, locks: Pointer[LockManager, Self.origin]):
        """
        Initializes the LockedContext.

        Args:
            locks: The LockManager to handle.
        """
        with Zone(
            function_name="LockedContext.__init__(locks: Pointer[LockManager])"
        ):
            self._locks = locks
            self._lock = 0

    @always_inline
    def __enter__(mut self) raises LarecsError -> Self:
        """
        Locks the world.

        Returns:
            The LockedContext.

        Raises:
            LarecsError: If the number of locks exceeds 256.
        """
        with Zone(function_name="LockedContext.__enter__()"):
            try:
                self._lock = self._locks[].lock()
            except:
                raise LarecsError(WorldError.out_of_locks)

            return self

    @always_inline
    def __exit__(mut self):
        """
        Unlocks the world.
        """
        with Zone(function_name="LockedContext.__exit__()"):
            try:
                self._locks[].unlock(self._lock)
            except e:
                assert (
                    False
                ), "An unexpected internal error occurred: " + String(e)

    # @always_inline
    # def __exit__[
    #     ErrType: AnyType
    # ](mut self, err: ErrType) raises LarecsError -> Bool:
    #     """
    #     Handles exceptions raised during the context.

    #     Returns:
    #         False to indicate the exception should be propagated.
    #     """
    #     comptime type_name = reflect[ErrType].name()

    #     self.__exit__()

    #     comptime if type_name == "LarecsError":
    #         return False
    #     elif conforms_to(ErrType, Writable):
    #         assert False, "An unexpected internal error occurred: " + String(
    #             err
    #         )
    #     else:
    #         assert False, "An unexpected internal error occurred: " + type_name

    #     return True
