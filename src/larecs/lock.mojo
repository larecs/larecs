from tracy import Zone

from .bitmask import BitMask
from .pool import BitPool
from ._internal_error import InternalError


@fieldwise_init
struct LockManager(Copyable, Movable):
    """
    Manages locks by mask bits.

    The number of simultaneous locks at a given time is limited internally (currently 256).
    """

    var locks: BitMask  # The actual locks.
    """The active lock bits."""
    var bit_pool: BitPool  # The bit pool for getting and recycling bits.
    """Pool used to allocate and recycle lock bit indices."""

    @always_inline
    def __init__(out self):
        """Initializes an unlocked lock manager."""
        with Zone(function_name="LockManager.__init__()"):
            self.locks = BitMask()
            self.bit_pool = BitPool()

    @always_inline
    def lock(mut self, out lock: Int) raises InternalError:
        """
        Locks the world and gets the Lock bit for later unlocking.

        Raises:
            InternalError: If the number of locks exceeds 256.
        """
        with Zone(function_name="LockManager.lock()"):
            try:
                lock = self.bit_pool.get()
            except:
                raise InternalError.out_of_locks

            self.locks.set[True](lock)

    @always_inline
    def unlock(mut self, lock: Int) raises InternalError:
        """
        Unlocks the given lock bit.

        Raises:
            LockError: If the lock is not set.
        """
        with Zone(function_name="LockManager.unlock(lock: Int)"):
            if not self.locks.get(lock):
                raise InternalError.unbalanced_unlock

            self.locks.set[False](lock)
            self.bit_pool.recycle(lock)

    @always_inline
    def is_locked(self) -> Bool:
        """
        IsLocked returns whether the world is locked by any queries.
        """
        with Zone(function_name="LockManager.is_locked()"):
            return not self.locks.is_zero()

    @always_inline
    def reset(mut self):
        """
        Reset the locks and the pool.
        """
        with Zone(function_name="LockManager.reset()"):
            self.locks = BitMask()
            self.bit_pool.reset()

    # @always_inline
    # def locked(mut self) -> LockedContext[origin_of(self)]:
    #     """
    #     Returns a locked context.
    #     """
    #     return LockedContext(Pointer(to=self))
