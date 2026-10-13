"""Target-local atomic scalars and nonblocking scoped reader/writer access.

Owners are noncopyable. Views borrow stable storage; copying a view preserves
the same protection identity. These primitives do not transfer host pointers
to a device or supply deferred execution. Device access is experimental.
"""

from std.atomic import Atomic, Ordering
from std.sys.info import is_gpu, is_amd_gpu, is_apple_gpu

comptime _scope = "agent" if is_amd_gpu() else "device" if is_gpu() and not is_apple_gpu() else ""
comptime _writer = UInt32(0x80000000)
comptime _max_readers = UInt32(0x7FFFFFFF)


@always_inline
def _validate_type[T: Movable & Deinitable]():
    """Checks the initial atomic scalar types.

    Parameters:
        T: Scalar type, restricted to UInt32 or Int32.

    Constraints:
        T must be UInt32 or Int32.
    """
    comptime assert T == UInt32 or T == Int32, "Atomics require UInt32 or Int32"


@fieldwise_init
struct CompareExchangeResult[T: ImplicitlyCopyable & Deinitable](
    Copyable, Movable
):
    """Outcome of one strong compare-exchange.

    Parameters:
        T: The observed scalar's type.
    """

    var exchanged: Bool
    """Whether this call replaced the expected value."""
    var observed: Self.T
    """Value compared by the atomic operation, not a later stable snapshot."""


struct AtomicView[
    writable: Bool, T: ImplicitlyCopyable & Deinitable, origin: Origin
](Copyable, Movable):
    """Atomic-only access to borrowed target-local scalar storage.

    Parameters:
        writable: Whether updates are permitted.
        T: UInt32 or Int32.
        origin: Storage borrow retained by this view.

    Notes:
        Construct views through an owner. Raw construction is internal and
        requires aligned live storage accessed exclusively through atomics.
    """

    var _pointer: Pointer[Self.T, Self.origin]

    def __init__(out self, *, deinit move: Self):
        """Moves the borrow without making it eligible for raw-byte transfer.

        Args:
            move: View whose storage identity and origin are preserved.
        """
        self._pointer = move._pointer

    def __deinit__(deinit self):
        """Ends the borrow without destroying its storage.

        Notes:
            Explicit move/destruction keeps raw-byte resource and capture
            validation from treating borrowed host pointers as device values.
        """
        pass

    def __init__(out self, *, unsafe_pointer: Pointer[Self.T, Self.origin]):
        """Borrows raw atomic storage under an explicit unsafe contract.

        Args:
            unsafe_pointer: Naturally aligned target-local UInt32/Int32 storage,
                kept live and accessed only atomically while this view exists.
                Writable views require a mutable pointer origin.
        """
        _validate_type[Self.T]()
        comptime assert (
            not Self.writable or Self.origin.mut
        ), "Atomic view is read-only"
        self._pointer = unsafe_pointer

    @always_inline
    def load[ordering: Ordering = Ordering.RELAXED](self) -> Self.T:
        """Loads the current scalar atomically.

        Parameters:
            ordering: Relaxed or acquire ordering.

        Returns:
            The observed value.

        Constraints:
            Ordering must be relaxed or acquire.
        """
        _validate_type[Self.T]()
        _validate_target_order[ordering]()
        comptime assert (
            ordering == Ordering.RELAXED or ordering == Ordering.ACQUIRE
        ), "Invalid atomic load ordering"
        comptime dtype = DType.uint32 if Self.T == UInt32 else DType.int32
        return rebind[Self.T](
            Atomic[dtype, scope=_scope].load[ordering=ordering](
                self._pointer.unsafe_bitcast[Scalar[dtype]]()
            )
        )

    @always_inline
    def store[ordering: Ordering = Ordering.RELAXED](self, value: Self.T):
        """Stores a scalar atomically.

        Parameters:
            ordering: Relaxed or release ordering.

        Args:
            value: Value to publish.

        Constraints:
            The view must allow updates; ordering is relaxed or release.
        """
        _validate_type[Self.T]()
        _validate_target_order[ordering]()
        comptime assert (
            Self.writable and Self.origin.mut
        ), "Atomic view is read-only"
        comptime assert (
            ordering == Ordering.RELAXED or ordering == Ordering.RELEASE
        ), "Invalid atomic store ordering"
        comptime dtype = DType.uint32 if Self.T == UInt32 else DType.int32
        Atomic[dtype, scope=_scope].store[ordering=ordering](
            self._pointer.unsafe_mut_cast[True]().unsafe_bitcast[
                Scalar[dtype]
            ](),
            rebind[Scalar[dtype]](value),
        )

    @always_inline
    def compare_exchange[
        ordering: Ordering = Ordering.RELAXED
    ](self, expected: Self.T, desired: Self.T) -> CompareExchangeResult[Self.T]:
        """Attempts one strong atomic comparison and replacement.

        Parameters:
            ordering: Success ordering; failure is always relaxed.

        Args:
            expected: Value to compare against.
            desired: Value to store on a match.

        Returns:
            Success and the value used by the comparison.

        Constraints:
            The view must allow updates and ordering must be a supported RMW order.
        """
        _validate_type[Self.T]()
        _validate_target_order[ordering]()
        comptime assert (
            Self.writable and Self.origin.mut
        ), "Atomic view is read-only"
        _validate_rmw_order[ordering]()
        _validate_target_order[ordering]()
        comptime dtype = DType.uint32 if Self.T == UInt32 else DType.int32
        comptime assert (
            not is_apple_gpu()
        ), "Strong compare-exchange is unavailable on Apple GPU in Mojo 1.0"
        var observed = rebind[Scalar[dtype]](expected)
        var exchanged = Atomic[dtype, scope=_scope].compare_exchange[
            success_ordering=ordering,
            failure_ordering=Ordering.RELAXED,
            weak=False,
        ](
            self._pointer.unsafe_mut_cast[True]().unsafe_bitcast[
                Scalar[dtype]
            ](),
            observed,
            rebind[Scalar[dtype]](desired),
        )
        return {exchanged, rebind[Self.T](observed)}

    @always_inline
    def fetch_add[
        ordering: Ordering = Ordering.RELAXED
    ](self, delta: Self.T) -> Self.T:
        """Adds with fixed-width wrapping arithmetic.

        Parameters:
            ordering: Ordering of the read-modify-write operation.

        Args:
            delta: Amount to add.

        Returns:
            The value before this update.

        Constraints:
            The view must allow updates and ordering must be a supported RMW order.
        """
        _validate_type[Self.T]()
        _validate_target_order[ordering]()
        comptime assert (
            Self.writable and Self.origin.mut
        ), "Atomic view is read-only"
        _validate_rmw_order[ordering]()
        _validate_target_order[ordering]()
        comptime dtype = DType.uint32 if Self.T == UInt32 else DType.int32
        return rebind[Self.T](
            Atomic[dtype, scope=_scope].fetch_add[ordering=ordering](
                self._pointer.unsafe_mut_cast[True]().unsafe_bitcast[
                    Scalar[dtype]
                ](),
                rebind[Scalar[dtype]](delta),
            )
        )

    @always_inline
    def fetch_sub[
        ordering: Ordering = Ordering.RELAXED
    ](self, delta: Self.T) -> Self.T:
        """Subtracts with fixed-width wrapping arithmetic.

        Parameters:
            ordering: Ordering of the read-modify-write operation.

        Args:
            delta: Amount to subtract.

        Returns:
            The value before this update.

        Constraints:
            The view must allow updates and ordering must be a supported RMW order.
        """
        # Compute modular negation as unsigned bits, including Int32.min.
        comptime dtype = DType.uint32 if Self.T == UInt32 else DType.int32
        var bits = rebind[Scalar[dtype]](delta).cast[DType.uint32]()
        var negated = UInt32(0) - bits
        return self.fetch_add[ordering](rebind[Self.T](negated.cast[dtype]()))


@always_inline
def _validate_target_order[ordering: Ordering]():
    """Rejects unvalidated Apple GPU publication orderings.

    Parameters:
        ordering: Requested memory ordering.

    Constraints:
        Apple GPU is restricted to the initial relaxed scalar API in this slice.
    """
    comptime assert (
        not is_apple_gpu() or ordering == Ordering.RELAXED
    ), "Apple GPU publication ordering is not supported by Larecs yet"


@always_inline
def _validate_rmw_order[ordering: Ordering]():
    """Checks a public read-modify-write ordering.

    Parameters:
        ordering: Requested memory ordering.

    Constraints:
        Ordering must be relaxed, acquire, release, or acquire-release.
    """
    comptime assert (
        ordering == Ordering.RELAXED
        or ordering == Ordering.ACQUIRE
        or ordering == Ordering.RELEASE
        or ordering == Ordering.ACQUIRE_RELEASE
    ), "Invalid atomic update ordering"


struct AtomicValue[T: ImplicitlyCopyable & Deinitable](Movable):
    """Owns a noncopyable atomic scalar without exposing ordinary references.

    Parameters:
        T: UInt32 or Int32.
    """

    var _value: Self.T

    def __init__(out self, value: Self.T):
        """Initializes exclusively owned scalar storage.

        Args:
            value: Initial value, before publication to workers.

        Constraints:
            T must be UInt32 or Int32.
        """
        _validate_type[Self.T]()
        self._value = value.copy()

    def read_view(ref self) -> AtomicView[False, Self.T, origin_of(self)]:
        """Borrows a view permitting only atomic loads.

        Returns:
            A view that cannot outlive or invalidate its owner.
        """
        return {
            unsafe_pointer = Pointer(to=self._value).unsafe_origin_cast[
                origin_of(self)
            ]()
        }

    def write_view(mut self) -> AtomicView[True, Self.T, origin_of(self)]:
        """Borrows an update-capable view, shareable among workers.

        Returns:
            A view whose copies refer to the same atomic storage.
        """
        return {
            unsafe_pointer = Pointer(to=self._value).unsafe_origin_cast[
                origin_of(self)
            ]()
        }


struct _AccessGuard[writable: Bool, T: Movable & Deinitable, origin: Origin](
    Movable
):
    """Noncopyable ownership of one acquired protection domain.

    Parameters:
        writable: Whether this is the exclusive writer.
        T: Protected payload type.
        origin: Owner borrow retained until release.
    """

    var _payload: Pointer[Self.T, Self.origin]
    var _state: Pointer[UInt32, MutUntrackedOrigin]

    def __init__(
        out self,
        payload: Pointer[Self.T, Self.origin],
        state: Pointer[UInt32, MutUntrackedOrigin],
    ):
        """Constructs a guard after successful acquisition; internal use only.

        Args:
            payload: Live protected payload.
            state: Domain whose reader count or writer bit is already acquired.
        """
        self._payload = payload
        self._state = state

    def __deinit__(deinit self):
        """Releases the acquired domain once on normal scope exit."""
        self._unlock()

    @always_inline
    def _unlock(self):
        """Releases state after every borrowed payload reference has ended."""
        comptime if Self.writable:
            Atomic[DType.uint32, scope=_scope].store[ordering=Ordering.RELEASE](
                self._state, UInt32(0)
            )
        else:
            _ = Atomic[DType.uint32, scope=_scope].fetch_add[
                ordering=Ordering.RELEASE
            ](self._state, UInt32(0xFFFFFFFF))

    def value(mut self) -> ref[origin_of(self)] Self.T where Self.writable:
        """Lends the writer payload for no longer than this guard's borrow.

        Returns:
            Mutable payload reference confined to this guard.
        """
        return self._payload.unsafe_mut_cast[True]().unsafe_origin_cast[
            origin_of(self)
        ]()[]

    def value(self) -> ref[origin_of(self)] Self.T where not Self.writable:
        """Lends an immutable payload reference tied to this read guard.

        Returns:
            Immutable payload reference confined to this guard.
        """
        return self._payload.unsafe_mut_cast[False]().unsafe_origin_cast[
            origin_of(self)
        ]()[]

    def release(deinit self):
        """Consumes the guard and releases through destruction.

        Constraints:
            No reference borrowed from this guard may remain live.
        """
        self._unlock()


struct TryAccess[Guard: Movable & Deinitable](Movable):
    """Owns an acquired guard or represents contention without payload access.

    Parameters:
        Guard: Noncopyable guard type.
    """

    var _guard: Optional[Self.Guard]

    def __init__(out self, var guard: Optional[Self.Guard]):
        """Initializes an acquired or busy result.

        Args:
            guard: Acquired guard, or None for Busy.
        """
        self._guard = guard^

    def is_acquired(self) -> Bool:
        """Reports whether this result owns a guard.

        Returns:
            True if access was acquired; False for Busy.
        """
        return Bool(self._guard)

    def take(deinit self) -> Self.Guard:
        """Consumes an acquired result and transfers its guard.

        Returns:
            The acquired guard.

        Constraints:
            Is_acquired must be true; an empty result triggers Optional's check.
        """
        var guard = self._guard^
        return guard.take()


struct SyncView[writable: Bool, T: Movable & Deinitable, origin: Origin](
    Copyable, Movable
):
    """Borrowed access capability sharing one reader/writer protection identity.

    Parameters:
        writable: Whether exclusive acquisition is permitted.
        T: Protected payload type.
        origin: Storage borrow retained by this view and its guards.

    Notes:
        Raw construction is internal; the state and payload must share one
        stable protection identity and remain live until all views expire.
    """

    var _payload: Pointer[Self.T, Self.origin]
    var _state: Pointer[UInt32, MutUntrackedOrigin]

    def __init__(out self, *, deinit move: Self):
        """Moves a capability without moving protected storage or its state.

        Args:
            move: Capability whose protection identity and origin are preserved.
        """
        self._payload = move._payload
        self._state = move._state

    def __deinit__(deinit self):
        """Ends the borrow without releasing a guard or destroying storage.

        Notes:
            Explicit move/destruction prevents raw-byte resource/capture
            transfer, including transfer of aggregates containing this view.
        """
        pass

    def __init__(
        out self,
        *,
        unsafe_payload: Pointer[Self.T, Self.origin],
        unsafe_state: Pointer[UInt32, MutUntrackedOrigin],
    ):
        """Borrows target-local payload and its canonical protection domain.

        Args:
            unsafe_payload: Payload accessed only through guards for this domain.
            unsafe_state: Aligned state initialized before workers start, shared
                by every overlapping view, and live for the entire borrow.

        Constraints:
            Writable views require a mutable payload origin.
        """
        comptime assert (
            not Self.writable or Self.origin.mut
        ), "Synchronized view is read-only"
        self._payload = unsafe_payload
        self._state = unsafe_state

    def try_read(self) -> TryAccess[_AccessGuard[False, Self.T, Self.origin]]:
        """Attempts shared access with at most one strong compare-exchange.

        Returns:
            An immutable guard, or Busy for conflicting/changed/saturated state.
        """
        comptime assert (
            not is_apple_gpu()
        ), "Reader/writer guards are unavailable on Apple GPU in Mojo 1.0"
        var state = Atomic[DType.uint32, scope=_scope].load[
            ordering=Ordering.RELAXED
        ](self._state)
        if state >= _max_readers:
            return {None}
        var acquired = Atomic[DType.uint32, scope=_scope].compare_exchange[
            success_ordering=Ordering.ACQUIRE,
            failure_ordering=Ordering.RELAXED,
            weak=False,
        ](self._state, state, state + UInt32(1))
        if not acquired:
            return {None}
        return {
            _AccessGuard[False, Self.T, Self.origin](self._payload, self._state)
        }

    def try_write(self) -> TryAccess[_AccessGuard[True, Self.T, Self.origin]]:
        """Attempts exclusive access with one strong compare-exchange.

        Returns:
            A mutable guard, or Busy.

        Constraints:
            This view must permit writes.
        """
        comptime assert (
            Self.writable and Self.origin.mut
        ), "Synchronized view is read-only"
        comptime assert (
            not is_apple_gpu()
        ), "Reader/writer guards are unavailable on Apple GPU in Mojo 1.0"
        var state = UInt32(0)
        var acquired = Atomic[DType.uint32, scope=_scope].compare_exchange[
            success_ordering=Ordering.ACQUIRE,
            failure_ordering=Ordering.RELAXED,
            weak=False,
        ](self._state, state, _writer)
        if not acquired:
            return {None}
        return {
            _AccessGuard[True, Self.T, Self.origin](self._payload, self._state)
        }


struct Synchronized[T: Movable & Deinitable](Movable):
    """Owns a stable payload and its noncopyable reader/writer domain.

    Parameters:
        T: Payload type; device use additionally requires a device-safe layout.
    """

    var _payload: Self.T
    var _state: UInt32

    def __init__(out self, var value: Self.T):
        """Initializes exclusively owned payload and unlocked state.

        Args:
            value: Payload transferred into this owner.
        """
        self._payload = value^
        self._state = 0

    def read_view(ref self) -> SyncView[False, Self.T, origin_of(self)]:
        """Borrows shared-read permission while retaining storage lifetime.

        Returns:
            A read capability sharing the owner's state word.
        """
        return {
            unsafe_payload = Pointer(to=self._payload).unsafe_origin_cast[
                origin_of(self)
            ](),
            unsafe_state = Pointer[UInt32, MutUntrackedOrigin](
                unsafe_from_address=Int(Pointer(to=self._state))
            ),
        }

    def write_view(mut self) -> SyncView[True, Self.T, origin_of(self)]:
        """Borrows shared-read and exclusive-write permissions.

        Returns:
            A capability whose copies preserve protection identity.
        """
        return {
            unsafe_payload = Pointer(to=self._payload).unsafe_origin_cast[
                origin_of(self)
            ](),
            unsafe_state = Pointer[UInt32, MutUntrackedOrigin](
                unsafe_from_address=Int(Pointer(to=self._state))
            ),
        }
