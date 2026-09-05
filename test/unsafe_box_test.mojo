from std.sys.info import size_of
from std.testing import *

from larecs.test_utils import *
from larecs.unsafe_box import UnsafeBox


@fieldwise_init
struct TestStruct:
    var value_1: Int
    var value_2: Float32


@fieldwise_init
struct ZeroSizedStruct(Copyable, Deinitable, Movable):
    """A zero-sized value used to test `UnsafeBox` with empty types."""

    pass


def test_unsafe_box_copy_move_del() raises:
    def factory(
        var val: MemTestStruct[
            MutUnsafeAnyOrigin, MutUnsafeAnyOrigin, MutUnsafeAnyOrigin
        ],
        out result: UnsafeBox,
    ):
        result = type_of(result)(val^)

    test_copy_move_del[factory](init_moves=1)


def test_unsafe_box_value() raises:
    var box = UnsafeBox(42)
    assert_equal(box.unsafe_get[Int](), 42)


def test_unsafe_box_zero_sized_value() raises:
    """A zero-sized value must not trip the box's "is empty" assertions.

    `_data` is legitimately `None` for a zero-sized value (there is nothing
    to allocate), which used to be indistinguishable from an uninitialized
    box and crashed under `-D ASSERT=all`.
    """
    comptime assert (
        size_of[ZeroSizedStruct]() == 0
    ), "ZeroSizedStruct must be zero-sized for this test to be meaningful."

    var box = UnsafeBox(ZeroSizedStruct())
    _ = box.unsafe_get[ZeroSizedStruct]()

    var copied = box.copy()
    _ = copied.unsafe_get[ZeroSizedStruct]()
    _ = copied^

    var moved = box^
    _ = moved.unsafe_get[ZeroSizedStruct]()
    _ = moved^


comptime functions = __functions_in_module()


def main() raises:
    var suite = TestSuite.discover_tests[functions]()
    suite^.run()
