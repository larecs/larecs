from std.testing import *

from larecs.test_utils import *
from larecs.unsafe_box import UnsafeBox


@fieldwise_init
struct TestStruct:
    var value_1: Int
    var value_2: Float32


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


comptime functions = __functions_in_module()


def main() raises:
    var suite = TestSuite.discover_tests[functions]()
    suite^.run()
