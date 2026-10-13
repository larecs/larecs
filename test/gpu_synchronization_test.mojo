# SKIP_ASAN
# SKIP_DEBUG
"""Device-wide synchronization validation on actual available accelerators."""

from max.gpu.host import DeviceContext
from std.gpu import global_idx
from std.sys import has_accelerator
from std.sys.info import has_apple_gpu_accelerator, is_apple_gpu, is_gpu
from std.testing import assert_equal, assert_true, TestSuite
from larecs.sync import AtomicView, SyncView


@fieldwise_init
struct Pair(Copyable, Movable):
    """Compound payload written under one protection domain."""

    var first: UInt32
    var second: UInt32


def atomic_increment(pointer: Pointer[UInt32, MutUntrackedOrigin]):
    """Performs the same scalar operation used by the CPU-worker tests.

    Args:
        pointer: Device-resident atomic counter shared by all blocks.
    """
    var view = AtomicView[True, UInt32, MutUntrackedOrigin](
        unsafe_pointer=pointer
    )
    for _ in range(32):
        _ = view.fetch_add(1)


def guarded_update(
    payload: Pointer[UInt32, MutUntrackedOrigin],
    state: Pointer[UInt32, MutUntrackedOrigin],
    completed: Pointer[UInt32, MutUntrackedOrigin],
    errors: Pointer[UInt32, MutUntrackedOrigin],
    reads: Pointer[UInt32, MutUntrackedOrigin],
):
    """Attempts bounded compound writes with device-wide protection.

    Args:
        payload: Two adjacent fields forming one protected Pair.
        state: Canonical domain state, initialized before launch.
        completed: Atomic count of successful writes.
        errors: Atomic count of inconsistent compound reads.
        reads: Atomic count of successful worker reads.
    """
    var view = SyncView[True, Pair, MutUntrackedOrigin](
        unsafe_payload=payload.unsafe_bitcast[Pair](), unsafe_state=state
    )
    var count = AtomicView[True, UInt32, MutUntrackedOrigin](
        unsafe_pointer=completed
    )
    var failures = AtomicView[True, UInt32, MutUntrackedOrigin](
        unsafe_pointer=errors
    )
    var read_count = AtomicView[True, UInt32, MutUntrackedOrigin](
        unsafe_pointer=reads
    )
    var index = 0
    comptime if is_gpu():
        index = global_idx.x
    # Every attempt is finite, including incompatible or changed state.
    for _ in range(16):
        if index % 2 == 0:
            var result = view.try_write()
            if result.is_acquired():
                var guard = result^.take()
                guard.value().first += 1
                guard.value().second += 1
                _ = count.fetch_add(1)
        else:
            var result = view.try_read()
            if result.is_acquired():
                var guard = result^.take()
                if guard.value().first != guard.value().second:
                    _ = failures.fetch_add(1)
                _ = read_count.fetch_add(1)


def coordinated_access(
    payload: Pointer[UInt32, MutUntrackedOrigin],
    state: Pointer[UInt32, MutUntrackedOrigin],
    outcomes: Pointer[UInt32, MutUntrackedOrigin],
):
    """Requires one worker read while every other lane attempts a blocked write.

    Args:
        payload: Two equal fields seeded before launch.
        state: Protocol fixture representing one existing reader, initialized to 1.
        outcomes: Successful reads, blocked writes, and errors, in that order.

    Notes:
        The fixture excludes writers without barriers or spinning. Only lane
        zero adds a reader, so its single CAS must succeed. Ending at state 1
        verifies it released exactly that additional reader.
    """
    var view = SyncView[True, Pair, MutUntrackedOrigin](
        unsafe_payload=payload.unsafe_bitcast[Pair](), unsafe_state=state
    )
    var reads = AtomicView[True, UInt32, MutUntrackedOrigin](
        unsafe_pointer=outcomes
    )
    var blocked = AtomicView[True, UInt32, MutUntrackedOrigin](
        unsafe_pointer=outcomes.unsafe_offset(1)
    )
    var errors = AtomicView[True, UInt32, MutUntrackedOrigin](
        unsafe_pointer=outcomes.unsafe_offset(2)
    )
    var index = 0
    comptime if is_gpu():
        index = global_idx.x
    if index == 0:
        var result = view.try_read()
        if result.is_acquired():
            var guard = result^.take()
            if guard.value().first != UInt32(
                123
            ) or guard.value().second != UInt32(123):
                _ = errors.fetch_add(1)
            _ = reads.fetch_add(1)
        else:
            _ = errors.fetch_add(1)
    else:
        var result = view.try_write()
        if result.is_acquired():
            _ = errors.fetch_add(1)
        else:
            _ = blocked.fetch_add(1)


def scalar_contract(results: Pointer[UInt32, MutUntrackedOrigin]):
    """Checks the common scalar API independently in each device lane.

    Args:
        results: One result cell per launched lane, each owned by that lane.
    """
    var index = 0
    comptime if is_gpu():
        index = global_idx.x
    var view = AtomicView[True, UInt32, MutUntrackedOrigin](
        unsafe_pointer=results.unsafe_offset(index)
    )
    view.store(7)
    var correct = view.fetch_add(2) == UInt32(7)
    correct = correct and view.fetch_sub(1) == UInt32(9)
    correct = correct and view.load() == UInt32(8)
    comptime if not is_apple_gpu():
        var outcome = view.compare_exchange(8, 10)
        correct = (
            correct and outcome.exchanged and outcome.observed == UInt32(8)
        )
        var failed = view.compare_exchange(8, 11)
        correct = (
            correct and not failed.exchanged and failed.observed == UInt32(10)
        )
    view.store(UInt32(correct))


def test_device_atomic_updates() raises:
    """Checks exact inter-block totals and supported per-lane scalar operations.

    Raises:
        Error: If device execution or result verification fails.
    """
    comptime if has_accelerator():
        var device = DeviceContext()
        var counter = device.enqueue_create_buffer[DType.uint32](1)
        var results = device.enqueue_create_buffer[DType.uint32](256)
        counter.enqueue_fill(0)
        device.enqueue_function[atomic_increment](
            counter.device_ptr(), grid_dim=4, block_dim=64
        )
        device.enqueue_function[scalar_contract](
            results.device_ptr(), grid_dim=4, block_dim=64
        )
        device.synchronize()
        with counter.map_to_host() as host:
            assert_equal(host[0], UInt32(4 * 64 * 32))
        with results.map_to_host() as host:
            for i in range(256):
                assert_equal(host[i], UInt32(1))
    else:
        print("SKIPPED GPU atomics: no accelerator available")


def test_device_guarded_updates() raises:
    """Checks exact compound writes and released state on supported backends.

    Raises:
        Error: If device execution or result verification fails.
    """
    comptime if has_accelerator() and not has_apple_gpu_accelerator():
        var device = DeviceContext()
        var payload = device.enqueue_create_buffer[DType.uint32](2)
        var state = device.enqueue_create_buffer[DType.uint32](1)
        var completed = device.enqueue_create_buffer[DType.uint32](1)
        payload.enqueue_fill(0)
        state.enqueue_fill(0)
        completed.enqueue_fill(0)
        var errors = device.enqueue_create_buffer[DType.uint32](1)
        errors.enqueue_fill(0)
        var reads = device.enqueue_create_buffer[DType.uint32](1)
        reads.enqueue_fill(0)
        device.enqueue_function[guarded_update](
            payload.device_ptr(),
            state.device_ptr(),
            completed.device_ptr(),
            errors.device_ptr(),
            reads.device_ptr(),
            grid_dim=4,
            block_dim=64,
        )
        device.synchronize()
        var expected: UInt32
        with completed.map_to_host() as host:
            expected = host[0]
            assert_true(expected > 0)
        with payload.map_to_host() as host:
            assert_equal(host[0], expected)
            assert_equal(host[1], expected)
        with errors.map_to_host() as host:
            assert_equal(host[0], UInt32(0))
        with state.map_to_host() as host:
            assert_equal(host[0], UInt32(0))
        with reads.map_to_host() as host:
            assert_true(host[0] <= UInt32(128 * 16))
        # A controlled existing-reader fixture guarantees worker read coverage
        # without assuming fairness in the mixed stress launch above.
        payload.enqueue_fill(123)
        state.enqueue_fill(1)
        var outcomes = device.enqueue_create_buffer[DType.uint32](3)
        outcomes.enqueue_fill(0)
        device.enqueue_function[coordinated_access](
            payload.device_ptr(),
            state.device_ptr(),
            outcomes.device_ptr(),
            grid_dim=4,
            block_dim=64,
        )
        device.synchronize()
        with outcomes.map_to_host() as host:
            assert_equal(host[0], UInt32(1))
            assert_equal(host[1], UInt32(255))
            assert_equal(host[2], UInt32(0))
        with state.map_to_host() as host:
            assert_equal(host[0], UInt32(1))
        state.enqueue_fill(0)
        device.synchronize()
    else:
        print("SKIPPED GPU guards: no supported accelerator available")


def main() raises:
    """Runs hardware synchronization validation when an accelerator is available.

    Raises:
        Error: If a test fails.
    """
    TestSuite.discover_tests[__functions_in_module()]().run()
