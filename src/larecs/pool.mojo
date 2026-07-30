from std.collections.check_bounds import check_bounds

from tracy import Zone

from .types import EntityId
from .entity import Entity
from ._internal_error import InternalError


struct EntityPool(Copyable, Movable, Sized):
    """EntityPool is an implementation using implicit linked lists.

    Implements https:#skypjack.github.io/2019-05-06-ecs-baf-part-3/
    """

    var _entities: List[Entity]
    """Entity storage and free-list links for recycled IDs."""
    var _next: EntityId
    """Next recycled entity ID or fresh allocation index."""
    var _available: Int
    """Number of recycled entities available for reuse."""

    @always_inline
    def __init__(out self):
        """Initializes an empty entity pool with the reserved zero entity."""
        with Zone(function_name="EntityPool.__init__()"):
            self._entities = List[Entity]()
            self._entities.append(Entity(0, UInt32(UInt16.MAX)))
            self._next = 0
            self._available = 0

    def get(mut self) -> Entity:
        """Returns a fresh or recycled entity."""
        with Zone(function_name="EntityPool.get()"):
            if self._available == 0:
                return self._get_new()

            curr = self._next
            self._entities[self._next]._id, self._next = (
                self._next,
                self._entities[self._next].get_id(),
            )
            self._available -= 1
            return self._entities[curr]

    @always_inline
    def _get_new(mut self, out entity: Entity):
        """Allocates and returns a new entity. For internal use."""
        with Zone(function_name="EntityPool._get_new(out entity: Entity)"):
            entity = Entity(EntityId(len(self._entities)))
            self._entities.append(entity)

    @always_inline
    def recycle(mut self, entity: Entity) raises InternalError:
        """Hands an entity back for recycling."""
        with Zone(function_name="EntityPool.recycle(entity: Entity)"):
            if entity.get_id() == 0:
                raise InternalError.mutation_of_zero_entity
            check_bounds(entity.get_id(), len(self._entities))

            self._entities[entity.get_id()]._generation += 1

            tmp = self._next
            self._next = entity.get_id()
            self._entities[entity.get_id()]._id = tmp
            self._available += 1

    @always_inline
    def reset(mut self):
        """Recycles all entities. Does NOT free the reserved memory."""
        with Zone(function_name="EntityPool.reset()"):
            self._entities.shrink(1)
            self._next = 0
            self._available = 0

    @always_inline
    def is_alive(self, entity: Entity) -> Bool:
        """Returns whether an entity is still alive, based on the entity's generations.
        """
        with Zone(function_name="EntityPool.is_alive(entity: Entity)"):
            return (
                entity._generation
                == self._entities[entity.get_id()]._generation
            )

    @always_inline
    def __len__(self) -> Int:
        """Returns the current number of used entities."""
        with Zone(function_name="EntityPool.__len__()"):
            return len(self._entities) - 1 - self._available

    @always_inline
    def capacity(self) -> Int:
        """Returns the current capacity (used and recycled entities)."""
        with Zone(function_name="EntityPool.capacity()"):
            return len(self._entities) - 1

    @always_inline
    def available(self) -> Int:
        """Returns the current number of available/recycled entities."""
        with Zone(function_name="EntityPool.available()"):
            return self._available


@fieldwise_init
struct BitPool(Copyable, Movable):
    """Pool of reusable bit indices.

    `BitPool` hands out unique bit indices in the range `0..<capacity` and
    recycles returned indices for later reuse. Recycled indices are stored as an
    implicit singly linked free list inside `_bits`, so allocation and recycling
    are O(1).
    """

    comptime capacity = Int(UInt8.MAX_FINITE) + 1
    """The maximum number of unique bit indices managed by the pool."""

    var _bits: Array[UInt8, Self.capacity]
    """Storage for allocated bit values and recycled free-list links."""

    var _next: Int
    """The head index of the recycled-bit free list."""

    var _available: Int
    """The number of recycled bits currently available for reuse."""

    # The length must be able to express that the pool is full.
    # Hence, the data type must be larger than the index
    # data type.
    var _length: Int
    """The number of unique bit indices allocated so far."""

    @always_inline
    def __init__(out self):
        """Initializes an empty bit pool.

        The pool starts with no allocated bits and no recycled bits. Fresh calls
        to [.BitPool.get] return monotonically increasing indices until recycled
        bits become available.
        """
        with Zone(function_name="BitPool.__init__()"):
            self._bits = Array[UInt8, Self.capacity](fill=0)
            self._next = 0
            self._length = 0
            self._available = 0

    def get(mut self, out bit_idx: Int) raises InternalError:
        """Returns a fresh or recycled bit index.

        Recycled indices are returned before allocating new indices. When no
        recycled index exists, the next fresh index is allocated.

        Raises:
            InternalError: If the pool is full.

        Returns:
            The acquired bit index.
        """
        with Zone(function_name="BitPool.get(out bit_idx: Int)"):
            if self._available == 0:
                bit_idx = self._next = self._get_new()
                return

            bit_idx = self._next
            self._next, self._bits[self._next] = (
                Int(self._bits[self._next]),
                UInt8(self._next),
            )
            self._available -= 1

    def _get_new(mut self, out bit_idx: Int) raises InternalError:
        """Allocates and returns a new bit index.

        This internal helper only allocates fresh indices; callers should use
        [.BitPool.get] so recycled indices are preferred.

        Raises:
            InternalError: If the pool is full.

        Returns:
            The index of the newly allocated bit.
        """
        with Zone(function_name="BitPool._get_new(out bit_idx: Int)"):
            if self._length >= Self.capacity:
                raise InternalError.ran_out_of_capacity

            bit_idx = self._length
            self._bits[self._length] = UInt8(bit_idx)
            self._length += 1

    @always_inline
    def recycle(mut self, bit_idx: Int):
        """Hands a bit index back for recycling.

        The recycled index becomes the head of the free list and may be returned
        by the next [.BitPool.get] call.

        Args:
            bit_idx: The index of the bit to recycle.
        """
        with Zone(function_name="BitPool.recycle(bit_idx: Int)"):
            check_bounds(bit_idx, self._length)
            self._next, self._bits[bit_idx] = bit_idx, UInt8(self._next)
            self._available += 1

    @always_inline
    def reset(mut self):
        """Resets the pool to its initial empty state.

        All previously handed-out indices are invalidated from the pool's point
        of view. The next allocation starts again at index 0.
        """
        self._next = 0
        self._length = 0
        self._available = 0
