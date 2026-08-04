from std.testing import *

from larecs._utils import concatenate_arrays


def test_concatenate_arrays_uint8() raises:
    left: Array[UInt8, 3] = [1, 2, 3]
    right: Array[UInt8, 2] = [4, 5]

    result = concatenate_arrays(left, right)

    assert_equal(len(result), 5)
    assert_equal(result[0], 1)
    assert_equal(result[1], 2)
    assert_equal(result[2], 3)
    assert_equal(result[3], 4)
    assert_equal(result[4], 5)


def test_concatenate_arrays_uint16() raises:
    left: Array[UInt16, 0] = []
    right: Array[UInt16, 2] = [3003, 4004]

    result = concatenate_arrays(left, right)

    assert_equal(len(result), 2)
    assert_equal(result[0], 3003)
    assert_equal(result[1], 4004)


comptime functions = __functions_in_module()


def main() raises:
    TestSuite.discover_tests[functions]().run()
