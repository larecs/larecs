# SKIP_DEBUG
# SKIP_ASAN
"""Explicit targets preserve dispatch and selected membership without fallback."""

from std.sys import has_accelerator
from std.sys.info import is_gpu
from std.testing import assert_equal, assert_true, TestSuite
from larecs import ExecutionBackend, World, SystemContext, KernelContext, Filter


def identify(rows: KernelContext[Filter().include[Int32]()]):
    """Records the actual compilation target in every visited row.

    Args:
        rows: Matching writable rows.
    """
    for row in rows:
        comptime if is_gpu():
            row.set(Int32(7))
        else:
            row.set(Int32(3))


def check_dispatch[backend: ExecutionBackend, selected: Bool]() raises:
    """Checks the target and exact selection membership.

    Parameters:
        backend: Requested compile-time execution target.
        selected: Whether to execute only newly added rows.

    Raises:
        Error: If dispatch or an assertion fails.
    """
    var world = World[Int32]()
    var untouched = world.storage.add_entity(Int32(0))
    var context = SystemContext(world)
    comptime if selected:
        var selection = context.add_entities(Int32(1), count=3)
        selection.run[identify, backend=backend]()
        selection^.release()
    else:
        _ = context.add_entities(Int32(1), count=3)
        context.run[identify, backend=backend]()
    var expected = Int32(3)
    comptime if backend == ExecutionBackend.DEVICE:
        expected = 7
    assert_equal(
        world.storage.get[Int32](untouched), 0 if selected else expected
    )
    var count = 0
    for row in world.storage.query[Filter().include[Int32]()]():
        if selected and row.get[Int32]() == 0:
            assert_equal(row.get[Int32](), 0)
        else:
            assert_equal(row.get[Int32](), expected)
            count += 1
    assert_equal(count, 3 if selected else 4)


def test_explicit_targets() raises:
    """Verifies ordinary and selected host/device dispatch.

    Raises:
        Error: If dispatch or verification fails.
    """
    check_dispatch[ExecutionBackend.HOST, False]()
    check_dispatch[ExecutionBackend.HOST, True]()
    comptime if has_accelerator():
        check_dispatch[ExecutionBackend.DEVICE, False]()
        check_dispatch[ExecutionBackend.DEVICE, True]()


def test_default_and_callable_host() raises:
    """Verifies the default and explicit HOST on both callable entry points.

    Raises:
        Error: If execution or verification fails.
    """
    var world = World[Int32]()
    var entity = world.storage.add_entity(Int32(0))
    var context = SystemContext(world)
    context.run[identify]()
    assert_equal(world.storage.get[Int32](entity), 3)
    var calls = 0

    def callable(rows: KernelContext[Filter().include[Int32]()]) {mut calls}:
        """Records host calls.

        Args:
            rows: Matching host rows.
        """
        calls += 1
        identify(rows)

    context.run[backend=ExecutionBackend.HOST](callable)
    var selection = context.add_entities(Int32(0), count=2)
    selection.run[identify]()
    selection.run[backend=ExecutionBackend.HOST](callable)
    selection^.release()
    assert_equal(calls, 2)


def test_unavailable_device() raises:
    """Rejects DEVICE even for empty selections and leaves HOST usable.

    Raises:
        Error: If an assertion or host execution fails.
    """
    var world = World[Int32]()
    var entity = world.storage.add_entity(Int32(0))
    world._device_storage = None
    var context = SystemContext(world)
    var rejected = False
    try:
        context.run[identify, backend=ExecutionBackend.DEVICE]()
    except e:
        rejected = True
        comptime if has_accelerator():
            assert_true("working device context" in String(e))
        else:
            assert_true("requires accelerator support" in String(e))
    assert_true(rejected)
    var selection = context._empty_selection()
    rejected = False
    try:
        selection.run[identify, backend=ExecutionBackend.DEVICE]()
    except e:
        rejected = True
        assert_true("requires" in String(e))
    assert_true(rejected)
    selection^.release()
    assert_equal(world.storage.get[Int32](entity), 0)
    context.run[identify, backend=ExecutionBackend.HOST]()
    assert_equal(world.storage.get[Int32](entity), 3)


def main() raises:
    """Runs explicit backend regressions.

    Raises:
        Error: If a test fails.
    """
    TestSuite.discover_tests[__functions_in_module()]().run()
