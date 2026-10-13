"""Ownership, publication, and actual host-worker synchronization checks."""

from max.algorithm import parallelize
from std.atomic import Ordering
from std.memory import is_trivially_movable, is_trivially_deletable
from larecs.resource import constrain_device_safe_resources
from std.testing import (
    assert_equal,
    assert_false,
    assert_true,
    assert_raises,
    TestSuite,
)
from larecs.sync import AtomicValue, Synchronized, SyncView


@fieldwise_init
struct Pair(Copyable, Movable):
    """Two fields that must always be observed in the same generation."""

    var first: UInt32
    var second: UInt32


@fieldwise_init
struct WrappedView[V: Copyable & Deinitable](Copyable, Movable):
    """Checks that raw-transfer rejection survives ordinary wrapper structs.

    Parameters:
        V: Borrowed synchronization view type.
    """

    var view: Self.V


def test_views_cannot_use_raw_device_transfer() raises:
    """Rejects direct and wrapped views through resource/capture checks.

    Raises:
        Error: If a borrowed host pointer view permits raw device transfer.
    """
    var owner = AtomicValue[UInt32](0)
    var atomic = owner.write_view()
    comptime A = type_of(atomic)
    var copied = atomic.copy()
    var moved = copied^
    _ = moved.fetch_add(1)
    assert_equal(atomic.load(), UInt32(1))
    assert_false(is_trivially_movable[A]())
    assert_false(is_trivially_deletable[A]())
    assert_false(constrain_device_safe_resources[A]())
    assert_false(constrain_device_safe_resources[WrappedView[A]]())
    assert_false(is_trivially_deletable[WrappedView[A]]())
    var protected = Synchronized[UInt32](0)
    var view = protected.write_view()
    comptime S = type_of(view)
    var copied_view = view.copy()
    var moved_view = copied_view^
    var acquired = moved_view.try_read()
    var guard = acquired^.take()
    assert_equal(guard.value(), UInt32(0))
    assert_false(is_trivially_movable[S]())
    assert_false(is_trivially_deletable[S]())
    assert_false(constrain_device_safe_resources[S]())
    assert_false(constrain_device_safe_resources[WrappedView[S]]())
    assert_false(is_trivially_deletable[WrappedView[S]]())


def test_atomic_operations_and_wrapping() raises:
    """Checks return values, CAS failure, explicit orders, and signed boundaries.

    Raises:
        Error: If an atomic contract differs from its expected value.
    """
    var owner = AtomicValue[UInt32](0xFFFFFFFF)
    var view = owner.write_view()
    assert_equal(view.fetch_add(1), UInt32(0xFFFFFFFF))
    assert_equal(view.load(), UInt32(0))
    assert_equal(view.fetch_sub(1), UInt32(0))
    view.store[Ordering.RELEASE](7)
    assert_equal(view.load[Ordering.ACQUIRE](), UInt32(7))
    var failed = view.compare_exchange(8, 9)
    assert_false(failed.exchanged)
    assert_equal(failed.observed, UInt32(7))
    var changed = view.compare_exchange[Ordering.ACQUIRE_RELEASE](7, 10)
    assert_true(changed.exchanged)
    assert_equal(changed.observed, UInt32(7))
    assert_equal(view.fetch_sub[Ordering.ACQUIRE_RELEASE](3), UInt32(10))
    assert_equal(view.fetch_add[Ordering.ACQUIRE](2), UInt32(7))
    assert_equal(view.fetch_add[Ordering.RELEASE](0), UInt32(9))
    var signed = AtomicValue[Int32](0x7FFFFFFF)
    var signed_view = signed.write_view()
    assert_equal(signed_view.fetch_add(1), Int32(0x7FFFFFFF))
    assert_equal(signed_view.load(), Int32(-2147483648))
    assert_equal(signed_view.fetch_sub(Int32(-2147483648)), Int32(-2147483648))
    assert_equal(signed_view.load(), Int32(0))
    assert_equal(signed_view.fetch_sub(0), Int32(0))


def test_shared_reads_and_exclusive_writes() raises:
    """Checks coexistence, exclusion, view identity, and explicit consuming release.

    Raises:
        Error: If read/write access or payload preservation is incorrect.
    """
    var owner = Synchronized[Pair](Pair(1, 1))
    var view = owner.write_view()
    var shared_copy = view.copy()
    var first_result = view.try_read()
    var second_result = shared_copy.try_read()
    assert_true(first_result.is_acquired())
    assert_true(second_result.is_acquired())
    var first = first_result^.take()
    var second = second_result^.take()
    assert_equal(first.value().first, UInt32(1))
    assert_false(shared_copy.try_write().is_acquired())
    first^.release()
    assert_false(view.try_write().is_acquired())
    second^.release()
    var writer_result = shared_copy.try_write()
    assert_true(writer_result.is_acquired())
    var writer = writer_result^.take()
    assert_false(view.try_read().is_acquired())
    assert_false(view.try_write().is_acquired())
    writer.value().first = 2
    writer.value().second = 2
    writer^.release()
    var after_result = view.try_read()
    assert_true(after_result.is_acquired())
    var after = after_result^.take()
    assert_equal(after.value().first, UInt32(2))
    assert_equal(after.value().second, UInt32(2))


def _raise_with_guard[
    T: Movable & Deinitable, origin: Origin
](view: SyncView[True, T, origin]) raises:
    """Raises while an acquired guard is live.

    Parameters:
        T: Payload type.
        origin: View's owner borrow.

    Args:
        view: Uncontended write capability.

    Raises:
        Error: Deliberate failure to test scope cleanup.
    """
    var result = view.try_write()
    var guard = result^.take()
    _ = guard.value()
    raise Error("guard cleanup")


def test_result_destruction_move_and_error_cleanup() raises:
    """Checks unextracted result cleanup, moved guards, and error unwinding.

    Raises:
        Error: If any guard is released twice or not released.
    """
    var owner = Synchronized[UInt32](5)
    var view = owner.write_view()
    # Destroying an acquired result without extraction releases its guard.
    assert_true(view.try_write().is_acquired())
    var result = view.try_write()
    assert_true(result.is_acquired())
    var first = result^.take()
    var moved = first^
    assert_false(view.try_write().is_acquired())
    moved^.release()
    with assert_raises():
        _raise_with_guard(view)
    assert_true(view.try_write().is_acquired())
    var readonly_owner = Synchronized[UInt32](11)
    var readonly = readonly_owner.read_view()
    var reader_result = readonly.try_read()
    var reader = reader_result^.take()
    assert_equal(reader.value(), UInt32(11))


def test_reader_saturation_does_not_wrap() raises:
    """Checks the private counter boundary without allocating billions of guards.

    Raises:
        Error: If saturated acquisition corrupts state.
    """
    var owner = Synchronized[UInt32](0)
    owner._state = UInt32(0x7FFFFFFF)
    var view = owner.write_view()
    assert_false(view.try_read().is_acquired())
    assert_false(view.try_write().is_acquired())


def test_parallel_atomic_totals() raises:
    """Checks exact totals using multiple CPU workers, not sequential iteration.

    Raises:
        Error: If increments are lost or return values duplicate.
    """
    var owner = AtomicValue[UInt32](0)
    var view = owner.write_view()
    var sum_owner = AtomicValue[UInt32](0)
    var totals = sum_owner.write_view()

    def worker(index: Int) {imm view, imm totals}:
        """Accumulates previous values of atomic increments.

        Args:
            index: Worker identifier.
        """
        for _ in range(1000):
            _ = totals.fetch_add(view.fetch_add(1))

    parallelize(worker, 8, 4)
    assert_equal(view.load(), UInt32(8000))
    assert_equal(totals.load(), UInt32(8000 * 7999 // 2))


def test_parallel_guard_exclusion_and_publication() raises:
    """Checks compound payload visibility and exact successful-operation counts.

    Raises:
        Error: If exclusion, publication, or reader consistency fails.
    """
    var owner = Synchronized[Pair](Pair(0, 0))
    var view = owner.write_view()
    var counts_owner = AtomicValue[UInt32](0)
    var counts = counts_owner.write_view()
    var errors_owner = AtomicValue[UInt32](0)
    var errors = errors_owner.write_view()

    def worker(index: Int) {imm view, imm counts, imm errors}:
        """Attempts finite reads and writes against one shared domain.

        Args:
            index: Even workers write; odd workers read.
        """
        for _ in range(2000):
            if index % 2 == 0:
                var result = view.try_write()
                if result.is_acquired():
                    var guard = result^.take()
                    guard.value().first += 1
                    guard.value().second += 1
                    _ = counts.fetch_add(1)
            else:
                var result = view.try_read()
                if result.is_acquired():
                    var guard = result^.take()
                    if guard.value().first != guard.value().second:
                        _ = errors.fetch_add(1)

    parallelize(worker, 8, 4)
    assert_equal(errors.load(), UInt32(0))
    assert_true(counts.load() > 0)
    var result = view.try_read()
    assert_true(result.is_acquired())
    var guard = result^.take()
    assert_equal(guard.value().first, counts.load())
    assert_equal(guard.value().second, counts.load())


def main() raises:
    """Runs synchronization behavior and CPU concurrency checks.

    Raises:
        Error: If a test fails.
    """
    TestSuite.discover_tests[__functions_in_module()]().run()
