"""Focused sequential synchronization costs with equivalent scalar updates."""

from std.atomic import Atomic, Ordering
from std.benchmark import keep
from std.time import perf_counter_ns
from std.testing import assert_equal, assert_true
from larecs import AtomicValue, Synchronized

comptime ITERATIONS = 100_000


def measure[mode: Int]() raises:
    """Measures scalar increments, excluding setup and post-run validation.

    Parameters:
        mode: Plain scalar, upstream atomic, Larecs atomic, or guarded scalar.

    Raises:
        Error: If an uncontended operation fails or the final total is wrong.
    """
    var plain = UInt32(0)
    var pointer = Pointer(to=plain)
    var atomic = AtomicValue[UInt32](0)
    var atomic_view = atomic.write_view()
    var protected = Synchronized[UInt32](0)
    var view = protected.write_view()
    var start = perf_counter_ns()
    for _ in range(ITERATIONS):
        comptime if mode == 0:
            plain += 1
            keep(plain)
        elif mode == 1:
            var previous = Atomic[DType.uint32].fetch_add[
                ordering=Ordering.RELAXED
            ](pointer, UInt32(1))
            keep(previous)
        elif mode == 2:
            keep(atomic_view.fetch_add(1))
        else:
            var result = view.try_write()
            if not result.is_acquired():
                raise Error("Uncontended benchmark acquisition failed")
            var guard = result^.take()
            guard.value() += 1
            keep(guard.value())
    var elapsed = perf_counter_ns() - start
    comptime if mode < 2:
        assert_equal(plain, UInt32(ITERATIONS))
    elif mode == 2:
        assert_equal(atomic_view.load(), UInt32(ITERATIONS))
    else:
        var result = view.try_read()
        assert_true(result.is_acquired())
        var guard = result^.take()
        assert_equal(guard.value(), UInt32(ITERATIONS))
    comptime name = "plain" if mode == 0 else "upstream_atomic" if mode == 1 else "larecs_atomic" if mode == 2 else "write_guard"
    print("SYNC", name, ITERATIONS, Float64(elapsed) / Float64(ITERATIONS))


def main() raises:
    """Runs a bounded manual comparison without adding PR timing cases.

    Raises:
        Error: If any workload fails validation.
    """
    measure[0]()
    measure[1]()
    measure[2]()
    measure[3]()
