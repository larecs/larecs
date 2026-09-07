"""Locking of the world to prevent structural changes during iteration.

Provides `LockManager` for structural-change lock bits and `LockGuard` for
owning one bit until it is transferred into an owning container such as
`LockedWorldEntityIterator`. These types are not thread-synchronization
primitives.
"""

from tracy import Zone

from .bitmask import BitMask
from .pool import BitPool
from ._internal_error import InternalError
from .error import WorldError
from .debug_utils import debug_warn


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

        Returns:
            The acquired lock bit.
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

        Args:
            lock: The lock bit to release, as returned by `lock()`.

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

        Returns:
            True if any lock bit is currently set.
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


struct LockGuard[lock_origin: MutOrigin](Movable):
    """Owns one structural-change lock until destruction.

    Moving transfers ownership without acquiring another lock. The guard
    cannot be copied. Acquire it before constructing a value that needs
    protection during initialization, then transfer it into the owning
    container, such as `LockedWorldEntityIterator`.

    Parameters:
        lock_origin: The origin of the lock manager, which must outlive the guard.
    """

    var _manager: Pointer[LockManager, Self.lock_origin]
    var _lock: Int

    @always_inline
    def __init__(
        out self, manager: Pointer[LockManager, Self.lock_origin]
    ) raises:
        """Acquires one structural-change lock.

        Args:
            manager: The lock manager to acquire a lock from.

        Raises:
            Error: If no lock is available.
        """
        self._manager = manager
        try:
            self._lock = self._manager[].lock()
        except:
            raise Error(WorldError.out_of_locks.msg())

    def __deinit__(deinit self):
        """Releases the owned lock, warning if its bit was already cleared."""
        with Zone(function_name="LockGuard.__deinit__()"):
            try:
                self._manager[].unlock(self._lock)
            except _:
                debug_warn(
                    t"Failed to unlock the lock {self._lock}. This should not"
                    t" happen."
                )
