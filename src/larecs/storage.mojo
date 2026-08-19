from .archetype import Archetype, MutableEntityAccessor
from .bitmask import BitMask
from .debug_utils import debug_warn
from .component import (
    ComponentType,
    ComponentManager,
    constrain_components_unique,
)
from .entity import Entity, EntityLocation
from .error import (
    LarecsError,
    WorldError,
    ComponentError,
    EntityError,
    UnknownError,
)
from .graph import BitMaskGraph
from .lock import LockManager
from .pool import EntityPool
from .query import (
    Query,
    QueryInfo,
    _WorldEntityIterator,
    _ArchetypeIterator,
)
from .static_optional import StaticOptional
from .types import ComponentId
from ._utils import concatenate_arrays, assert_unreachable

from std.sys import size_of

from tracy import Zone


struct Storage[*ComponentTypes: ComponentType](Copyable):
    """
    Holds all the component and entity data for a world.

    This is always used in combination with a [..world.World] instance, e.g. as a member of it.

    Parameters:
        ComponentTypes: A variadic list with all possible component types for this storage.

    Examples:
        ```mojo
        var world = World[Position, Velocity]()
        world.storage.add_entitiy(Position(10.0, 20.0))
        ```
    """

    comptime component_manager = ComponentManager[*Self.ComponentTypes]

    # If *Ts is empty, this results in a zero-sized Array, else this
    # results in an Array of component IDs.
    comptime _optional_component_ids[
        *Ts: ComponentType
    ] = Self.component_manager.get_id_arr[*Ts]()
    """Component ID array type for an optional component type pack."""

    comptime Query = Query[
        _,
        _,
        *Self.ComponentTypes,
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
        *Self.ComponentTypes,
        has_start_indices=has_start_indices,
    ]
    """
    Primary entity iterator type comptime for mask-based Storage queries.

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
        *Self.ComponentTypes,
    ]
    """
    Archetype iterator type for iterating over archetypes matching a query.

    Parameters:
        archetype_mutability: Whether the iterator allows mutable access to archetypes.
        archetype_origin: The origin of the archetype data accessed by the iterator.
        has_without_mask: Whether the query has a without mask, which requires additional checks during iteration.
    """

    var _locks: LockManager
    """Lock manager guarding mutation during active iteration."""

    var _entity_pool: EntityPool  # Pool for entities.
    """Pool used to allocate and recycle entity IDs."""
    var _entity_locations: List[EntityLocation]
    """Mapping from entity IDs to their current archetype location."""

    comptime Archetype = Archetype[*Self.ComponentTypes]
    """Type alias for an archetype owned by this storage ."""

    comptime Archetypes = List[Self.Archetype]
    """Type alias for the list of archetypes owned by this storage."""

    var _archetypes: Self.Archetypes
    """Storage for all archetypes owned by this storage."""

    var _archetype_map: BitMaskGraph[-1]
    """Graph mapping component masks to archetype indices."""

    def __init__(out self):
        """
        Initializes the storage with the zero archetype and zero entity location.
        """
        self._entity_locations = [EntityLocation(0, 0)]
        self._entity_pool = EntityPool()

        self._archetype_map = BitMaskGraph[-1](0)
        self._archetypes = [Self.Archetype()]
        self._locks = LockManager()

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
                "Components.query[*Ts: ComponentType](out iterator: Self.Query)"
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

    @always_inline
    def _get_archetype_index[
        size: Int
    ](
        mut self,
        components: Array[ComponentId, size],
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
                "Components._get_archetype_index[size: Int](components:"
                " Array[ComponentId, size], start_node_index: Int)"
            )
        ):
            comptime assert 0 <= size, "Size must be non-negative."
            var node_index = self._archetype_map.get_node_index(
                components, start_node_index
            )
            if self._archetype_map.has_value(node_index):
                return self._archetype_map[node_index]

            var archetype_index = len(self._archetypes)
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
            function_name=(
                "Components._get_archetype_index_by_mask(mask: BitMask)"
            )
        ):
            for i in range(len(self._archetypes)):
                if self._archetypes[i].get_mask() == mask:
                    return i

            var node_index = self._archetype_map.add_node(mask.copy())
            var archetype_index = len(self._archetypes)
            self._archetypes.append(Self.Archetype(node_index, mask^))
            self._archetype_map[node_index] = archetype_index
            return archetype_index

    def add_entity[
        *Ts: ComponentType
    ](mut self, var *components: *Ts) raises LarecsError -> Entity:
        """Returns a new or recycled [..entity.Entity].

        The given component types are added to the entity.
        Do not use during [.Storage.query] iteration!

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
            Error: If the world is [.Storage.is_locked locked].

        Returns:
            The new or recycled [..entity.Entity].

        """
        with Zone(
            function_name=(
                "Storage.add_entity[*Ts: ComponentType](var *components: *Ts)"
            )
        ):
            comptime assert Self.component_manager.contains_components[
                *Ts
            ](), "Not all component types are in the component manager."
            comptime assert constrain_components_unique[
                *Ts
            ](), "Duplicate component types in add_entity are not allowed."

            self._assert_unlocked()

            comptime component_count = len(Ts)

            var archetype_index: Int
            comptime if component_count:
                archetype_index = self._get_archetype_index(
                    Self.component_manager.get_id_arr[*Ts]()
                )
            else:
                archetype_index = 0

            var entity_index = self._create_entities(archetype_index, 1)

            comptime if component_count:
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

            return self._archetypes[archetype_index].get_entity(entity_index)

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
        Do not use during [.Storage.query] iteration!

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
            LarecsError: If the world is [.Storage.is_locked locked].

        Returns:
            An iterator to the new or recycled [..entity.Entity Entities].

        """
        with Zone(
            function_name=(
                "Storage.add_entities[*Ts: ComponentType](*components: *Ts,"
                " count: Int, out iterator: Self.Iterator)"
            )
        ):
            comptime assert Self.component_manager.contains_components[
                *Ts
            ](), "Not all component types are in the component manager."
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

            var archetype_index: Int
            comptime if component_count:
                archetype_index = self._get_archetype_index(
                    Self.component_manager.get_id_arr[*Ts]()
                )
            else:
                archetype_index = 0

            var first_index_in_archetype = self._create_entities(
                archetype_index, count
            )

            ref archetype = self._archetypes.unsafe_get(archetype_index)

            comptime for i in range(component_count):
                comptime T = Ts[i]
                comptime assert Self.component_manager.contains_components[
                    T
                ](), "Component type is not part of the world."
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
    def _create_entities(mut self, archetype_index: Int, count: Int) -> Int:
        """
        Creates multiple [..entity.Entity Entities] and adds them to the given archetype.

        Returns:
            The index of the first newly created entity in the archetype.
        """
        with Zone(
            function_name=(
                "Storage._create_entities(archetype_index: Int, count: Int)"
            )
        ):
            debug_assert(count > 0, "Count must be positive.")
            ref archetype = self._archetypes.unsafe_get(archetype_index)
            var arch_start_idx = archetype.extend(count, self._entity_pool)
            var entities_size = (
                archetype.get_entity(arch_start_idx + count - 1).get_id() + 1
            )
            if entities_size > len(self._entity_locations):
                if entities_size > self._entity_locations.capacity():
                    self._entity_locations.reserve(
                        max(
                            entities_size, 2 * self._entity_locations.capacity()
                        )
                    )

                self._entity_locations.resize(
                    entities_size, EntityLocation(0, archetype_index)
                )

            for i in range(arch_start_idx, arch_start_idx + count):
                var entity_id = archetype.get_entity(i).get_id()
                self._entity_locations[
                    entity_id
                ].archetype_index = archetype_index
                self._entity_locations[entity_id].entity_index = i

            return arch_start_idx

    def remove_entity(mut self, entity: Entity) raises LarecsError:
        """
        Removes an [..entity.Entity], making it eligible for recycling.

        Do not use during [.Storage.query] iteration!

        Args:
            entity: The entity to remove.

        Raises:
            LarecsError: If the world is locked or the entity does not exist.
        """
        self._assert_unlocked()
        self._assert_alive(entity)

        with Zone(function_name="Storage.remove_entity(entity: Entity)"):
            var entity_loc = self._entity_locations[entity.get_id()]
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

            var swapped = old_archetype.remove(entity_loc.entity_index)

            try:
                self._entity_pool.recycle(entity)
            except:
                assert_unreachable(
                    "Zero Entity should never be handed via public API. So it"
                    " should never be recycled here!"
                )

            if swapped:
                var swap_entity = old_archetype.get_entity(
                    entity_loc.entity_index
                )
                self._entity_locations[
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
        world.storage.remove_entities(world.storage.query[Float32]())
        ```

        Args:
            query: The query to determine which entities to remove. Note, you can
                    either use [..query.Query] or [..query.QueryInfo].

        Raises:
            LarecsError: If the world is locked.
        """
        self._assert_unlocked()

        with Zone(function_name="Storage.remove_entities(query: QueryInfo)"):
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
        with Zone(function_name="Storage.is_alive(entity: Entity)"):
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
        with Zone(
            function_name="Storage.has[T: ComponentType](entity: Entity)"
        ):
            comptime assert Self.component_manager.contains_components[
                T
            ](), "Component type not in component manager"
            self._assert_alive(entity)
            return self._archetypes.unsafe_get(
                index(self._entity_locations[entity.get_id()].archetype_index)
            ).has_components[T]()

    @__unsafe_nested_origins_read_only
    @always_inline
    def get[
        T: ComponentType
    ](mut self, entity: Entity) raises LarecsError -> ref[
        origin_of(
            self._archetypes.unsafe_get(
                self._entity_locations[entity.get_id()].archetype_index
            )
        )
    ] T:
        """Returns a reference to the given component of an [..entity.Entity].

        Parameters:
            T: The type of the component. Constraints: Must be in the component manager.

        Raises:
            LarecsError: If the entity is not alive or does not have the component.
        """
        comptime assert Self.component_manager.contains_components[
            T
        ](), "Component type not in component manager"
        var entity_loc = self._entity_locations[entity.get_id()]
        self._assert_alive(entity)

        with Zone(
            function_name="Storage.get[T: ComponentType](entity: Entity)"
        ):
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
                "Storage.set[T: ComponentType](entity: Entity, var"
                " component: T)"
            )
        ):
            comptime assert Self.component_manager.contains_components[
                T
            ](), "Component type not in component manager"
            self._assert_alive(entity)
            var entity_loc = self._entity_locations[entity.get_id()]
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
                "Storage.set[*Ts: ComponentType](entity: Entity, var"
                " *components: *Ts)"
            )
        ):
            comptime assert Self.component_manager.contains_components[
                *Ts
            ](), "One or more component types not in component manager"
            comptime assert constrain_components_unique[
                *Ts
            ](), "Duplicate component types in set are not allowed."

            self._assert_alive(entity)
            var entity_loc = self._entity_locations[entity.get_id()]
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
            Error: when called on a locked world. Do not use during [.Storage.query] iteration.
        """
        with Zone(
            function_name=(
                "Storage.add[*Ts: ComponentType](entity: Entity, var"
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
            Error: when called on a locked world. Do not use during [.Storage.query] iteration.
        """
        with Zone(
            function_name=(
                "Storage.add[*Ts: ComponentType](var *add_components: *Ts,"
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

        for entity in world.storage.add[Velocity](
            world.storage.query[Position]().without_mask[Velocity](),
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
            Error: when called on a locked world. Do not use during [.Storage.query] iteration.
            Error: when called with a query that could match existing entities that already have at least one of the
                components to add.
        """
        with Zone(
            function_name=(
                "Storage.add[has_without_mask: Bool, *Ts: ComponentType](query:"
                " QueryInfo, var *add_components: *Ts, out iterator:"
                " Self.Iterator)"
            )
        ):
            comptime assert Self.component_manager.contains_components[
                *Ts
            ](), "One or more component types not in component manager"
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
            Error: when called on a locked world. Do not use during [.Storage.query] iteration.
        """
        with Zone(
            function_name="Storage.remove[*Ts: ComponentType](entity: Entity)"
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

        for entity in world.storage.remove[Velocity](
            world.storage.query[Position, Velocity]()
        ):
            position = entity.get[Position]()
        ```

        Parameters:
            Ts: The types of the components to remove. Constraints: Must be in the component manager and contain no duplicates.
            has_without_mask: Whether the query has a without mask.

        Args:
            query: The query to determine which entities to modify.

        Raises:
            Error: when called on a locked world. Do not use during [.Storage.query] iteration.
            Error: when called with a query that could match entities that don't have all of the components to remove.
        """

        with Zone(
            function_name=(
                "Storage.remove[*Ts: ComponentType, has_without_mask:"
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
            comptime assert Self.component_manager.contains_components[
                *Ts
            ](), "One or more component types not in component manager"

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
        *Self.ComponentTypes,
        remove_ids=Self.component_manager.get_id_arr[*Ts](),
    ]:
        """
        Returns a [.Replacer] for removing and adding components to an [..entity.Entity] in one go.

        Use as `world.replace[Comp1, Comp2]().by(comp3, comp4, comp5, entity=entity)`.

        The number of removed components does not need to match the number of added components.

        Parameters:
            Ts: The types of the components to remove.
        """
        with Zone(function_name="Storage.replace[*Ts: ComponentType]()"):
            comptime assert constrain_components_unique[
                *Ts
            ](), "Duplicate component types in replace are not allowed."

            return {Pointer(to=self)}

    @always_inline
    def _remove_and_add[
        *Ts: ComponentType,
        rem_size: Int = 0,
        remove_ids: Array[ComponentId, rem_size] = Array[ComponentId, rem_size](
            uninitialized=True
        ),
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
            Error: when called on a locked world. Do not use during [.Storage.query] iteration.
        """
        with Zone(
            function_name=(
                "Storage._remove_and_add[*Ts: ComponentType, rem_size: Int,"
                " remove_ids: Array[ComponentId, rem_size]](entity:"
                " Entity, var *add_components: *Ts)"
            )
        ):
            comptime assert Self.component_manager.contains_components[
                *Ts
            ](), "One or more component types not in component manager"
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

            var entity_loc = self._entity_locations[entity.get_id()]

            var old_archetype_idx = entity_loc.archetype_index
            ref old_archetype = self._archetypes.unsafe_get(old_archetype_idx)
            var old_archetype_mask = old_archetype.get_mask()

            var runtime_add_ids = materialize[add_ids]()
            var runtime_remove_ids = materialize[remove_ids]()

            comptime if rem_size:
                var remove_mask = BitMask(runtime_remove_ids)
                if not old_archetype_mask.contains(remove_mask):
                    raise LarecsError(
                        ComponentError.missing_components_on_remove.with_components(
                            old_archetype_mask ^ remove_mask
                        )
                    )

            comptime if add_size:
                var compare_mask = old_archetype_mask

                comptime if rem_size:
                    compare_mask.set(runtime_remove_ids, False)
                var add_mask = BitMask(runtime_add_ids)
                if compare_mask.contains(add_mask):
                    raise LarecsError(
                        ComponentError.existing_components_on_add.with_components(
                            compare_mask & add_mask
                        )
                    )

            comptime ComponentIdsType = Array[ComponentId, add_size + rem_size]
            comptime assert 0 <= add_size + rem_size

            var component_ids: ComponentIdsType
            comptime if add_size and rem_size:
                comptime concatenated = concatenate_arrays(remove_ids, add_ids)
                component_ids = materialize[concatenated]()
            elif Bool(add_size) and not rem_size:
                component_ids = rebind_var[ComponentIdsType](runtime_add_ids^)
            elif not add_size and Bool(rem_size):
                component_ids = rebind_var[ComponentIdsType](
                    runtime_remove_ids^
                )
            else:
                return

            var index_in_old_archetype = entity_loc.entity_index
            var new_archetype_idx = self._get_archetype_index(
                component_ids, old_archetype.get_node_index()
            )
            ref old_archetype = self._archetypes.unsafe_get(old_archetype_idx)
            ref new_archetype = self._archetypes.unsafe_get(new_archetype_idx)
            var index_in_new_archetype = new_archetype.add_entity(entity)

            # Move component data from old archetype to new archetype.
            comptime for id in range(Self.component_manager.component_count):
                comptime T = Self.ComponentTypes[id]
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

            var swapped = old_archetype.remove(index_in_old_archetype)
            if swapped:
                var swap_entity = old_archetype.get_entity(
                    entity_loc.entity_index
                )
                self._entity_locations[
                    swap_entity.get_id()
                ].entity_index = entity_loc.entity_index

            self._entity_locations[entity.get_id()] = EntityLocation(
                index_in_new_archetype, new_archetype_idx
            )

    @always_inline
    def _batch_remove_and_add[
        *Ts: ComponentType,
        rem_size: Int = 0,
        remove_ids: Array[ComponentId, rem_size] = Array[ComponentId, rem_size](
            uninitialized=True
        ),
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
            LarecsError: when called on a locked world. Do not use during [.Storage.query] iteration.
        """
        with Zone(
            function_name=(
                "Storage._batch_remove_and_add[*Ts: ComponentType, rem_size:"
                " Int, remove_ids: Array[ComponentId, rem_size],"
                " has_without_mask: Bool](query: QueryInfo, var"
                " *add_components: *Ts, out iterator: Self.Iterator)"
            )
        ):
            comptime assert Self.component_manager.contains_components[
                *Ts
            ](), "One or more component types not in component manager"
            comptime assert constrain_components_unique[
                *Ts
            ](), "Duplicate component types in add are not allowed."

            comptime add_size = len(Ts)
            comptime add_ids = Self.component_manager.get_id_arr[*Ts]()

            comptime ComponentIdsType = Array[ComponentId, add_size + rem_size]
            comptime assert 0 <= add_size + rem_size

            # Note:
            #    This operation can never map multiple archetypes onto one, due to the requirement that components to add
            #    must be excluded in the query. Therefore, we can apply the transformation to each matching archetype
            #    individually without checking for edge cases where multiple archetypes get merged into one.
            #    This also enables potential parallelization optimizations.

            var runtime_add_ids = materialize[add_ids]()
            var runtime_remove_ids = materialize[remove_ids]()

            var add_mask = BitMask(runtime_add_ids)
            var remove_mask = BitMask(runtime_remove_ids)

            comptime if add_size:
                # If query could match archetypes that already have at least one of the components, raise an error
                # FIXME: When https://github.com/modular/modular/issues/5347 is fixed, we can use short-circuiting here.

                var strict_check_needed: Bool

                comptime if has_without_mask:
                    strict_check_needed = not query.without_mask[].contains(
                        add_mask
                    )
                else:
                    strict_check_needed = True

                if strict_check_needed:
                    for archetype in self._get_archetype_iterator(
                        query.mask, query.without_mask
                    ):
                        var archetype_mask = archetype.get_mask()

                        comptime if rem_size:
                            archetype_mask.set(runtime_remove_ids, False)

                        if archetype and archetype_mask.contains_any(add_mask):
                            raise LarecsError(
                                ComponentError.existing_components_on_add_query.with_components(
                                    archetype_mask & add_mask
                                )
                            )

            comptime if rem_size:
                # If query could match archetypes that don't have all of the components, raise an error
                if not query.mask.contains(remove_mask):
                    raise LarecsError(
                        ComponentError.missing_components_on_remove_query.with_components(
                            query.mask ^ remove_mask
                        )
                    )

                comptime if has_without_mask:
                    if query.without_mask[].contains_any(remove_mask):
                        raise LarecsError(
                            ComponentError.missing_components_on_remove_query.with_components(
                                query.without_mask[] & remove_mask
                            )
                        )

            var component_ids: ComponentIdsType
            comptime if add_size and rem_size:
                comptime concatenated = concatenate_arrays(remove_ids, add_ids)
                component_ids = materialize[concatenated]()
            elif Bool(add_size) and not rem_size:
                component_ids = rebind_var[ComponentIdsType](runtime_add_ids^)
            elif not add_size and Bool(rem_size):
                component_ids = rebind_var[ComponentIdsType](
                    runtime_remove_ids^
                )
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
            var arch_start_idcs = List[Int](
                capacity=min(len(self._archetypes), _2kb_of_UInt_or_Int)
            )
            var changed_archetype_idcs = List[Int](
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
                    var old_node_index = old_archetype1.get_node_index()
                    var new_archetype_idx = self._get_archetype_index[
                        add_size + rem_size
                    ](component_ids, old_node_index)

                    # We need to update the pointer to the old archetype, because the `self._archetypes` list may have been
                    # resized during the call to `_get_archetype_index`.
                    var old_archetype_idx = self._archetype_map[old_node_index]
                    ref old_archetype = self._archetypes.unsafe_get(
                        index(old_archetype_idx)
                    )

                    ref new_archetype = self._archetypes.unsafe_get(
                        new_archetype_idx
                    )

                    # TODO: Optimization: If `new_archetype` is empty we can just shallow-copy the _ComponentTable of `old_archetype` to `new_archetype` and reinit `old_archetype`.

                    var old_archetype_size = len(old_archetype)
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

                    var old_archetype_unsafe = Pointer(
                        to=old_archetype
                    ).as_unsafe_any_origin()
                    var arch_start_idx = (
                        new_archetype.extend_from_archetype_unsafe(
                            old_archetype_unsafe, old_archetype_size
                        )
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
                        var entity = old_archetype.get_entity(entity_idx)
                        self._entity_locations[
                            entity.get_id()
                        ] = EntityLocation(
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
        with Zone(function_name="Storage._assert_unlocked()"):
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
        with Zone(function_name="Storage._assert_alive(entity: Entity)"):
            if not self._entity_pool.is_alive(entity):
                raise LarecsError(
                    EntityError.non_existent_entity.with_entities(entity)
                )

    @always_inline
    def apply[
        OperationType: def(accessor: MutableEntityAccessor) raises -> None,
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
                "Storage.apply[OperationType, has_without_mask: Bool, *,"
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

    # BUG: Mojo cannot correctly infer the simd_width for `Storage.apply` therefore disable this for now.
    #
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
    #             ptr = Pointer(to=component)
    #         except:
    #             return

    #         # Load a SIMD of size `simd_width`
    #         # Note that a strided load is needed if the component as more than one field.
    #         val = ptr.load[width=simd_width]()

    #         # Do an operation on the SIMD
    #         val += 1

    #         # Store the SIMD at the same address
    #         ptr.store(val)

    #     world.storage.apply[operation, simd_width=simdwidthof[Float64]()](world.storage.query[Float64]())
    #     ```

    #     """
    #     with TraceGuard(name="Storage.apply simd"):
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
                "Storage._get_entity_iterator[has_without_mask: Bool,"
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
                "Storage._get_archetype_iterator[has_without_mask: Bool](mask:"
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
        Returns whether the world is locked by any [.Storage.query queries].
        """
        with Zone(function_name="Storage.is_locked(out result: Bool)"):
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
        with Zone(function_name="Storage._lock(out lock: Int)"):
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
        with Zone(function_name="Storage._unlock(lock: Int)"):
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
        with Zone(function_name="Storage._locked()"):
            return LockedContext(Pointer(to=self._locks))


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


@fieldwise_init
struct Replacer[
    storage_origin: MutOrigin,
    size: Int,
    *ComponentTypes: ComponentType,
    remove_ids: Array[ComponentId, size],
]:
    """
    Replacer is a helper struct for removing and adding components to an [..entity.Entity].

    It stores the components to remove and allows adding new components
    in one go.

    Parameters:
        storage_origin: The mutable origin of the world.
        size: The number of components to remove.
        ComponentTypes: The types of the components.
        remove_ids: The IDs of the components to remove.
    """

    comptime Storage = Storage[*Self.ComponentTypes]
    """The Storage type modified by this replacer."""

    var _storage: Pointer[Self.Storage, Self.storage_origin]
    """Pointer to the storage modified by this replacer."""

    def by(self, entity: Entity) raises LarecsError:
        """
        Removes components from an [..entity.Entity].

        Args:
            entity: The entity to modify.

        Raises:
            Error: when called for a removed (and potentially recycled) entity.
            Error: when called with components that can't be removed because they are not present.
            Error: when called on a locked world. Do not use during [.Storage.query] iteration.
        """
        with Zone(function_name="Replacer.by(entity: Entity)"):
            self._storage[]._remove_and_add[
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
            Error: when called on a locked world. Do not use during [.Storage.query] iteration.
        """
        with Zone(
            function_name=(
                "Replacer.by[T: ComponentType](var component: T, entity:"
                " Entity)"
            )
        ):
            self._storage[]._remove_and_add[
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
            Error: when called on a locked world. Do not use during [.Storage.query] iteration.
        """
        with Zone(
            function_name=(
                "Replacer.by[*AddTs: ComponentType](var *components: *AddTs,"
                " entity: Entity)"
            )
        ):
            self._storage[]._remove_and_add[
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
        out iterator: Self.Storage.Iterator[
            origin_of(self._storage[]._archetypes),
            origin_of(self._storage[]._locks),
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
            Error: when called on a locked world. Do not use during [.Storage.query] iteration.
        """
        with Zone(
            function_name=(
                "Replacer.by[*AddTs: ComponentType, has_without_mask:"
                " Bool](query: QueryInfo, var *components: *AddTs, out"
                " iterator: Self.Storage.Iterator)"
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
        out iterator: Self.Storage.Iterator[
            origin_of(self._storage[]._archetypes),
            origin_of(self._storage[]._locks),
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
            Error: when called on a locked world. Do not use during [.Storage.query] iteration.
        """

        with Zone(
            function_name=(
                "Replacer.by[*AddTs: ComponentType, has_without_mask: Bool](var"
                " *components: *AddTs, query: QueryInfo, out iterator:"
                " Self.Storage.Iterator)"
            )
        ):
            return self._storage[]._batch_remove_and_add[
                rem_size=Self.size,
                remove_ids=Self.remove_ids,
            ](
                query,
                *components^,
            )
