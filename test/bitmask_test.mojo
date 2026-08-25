import std.random
from std.testing import *
from std.benchmark import keep
from larecs.bitmask import BitMask, _BitMask
from std.io.write import Writable, Writer


# ------ Helper functions ------


@always_inline
def get_random_bitmask() -> BitMask:
    var mask = BitMask()
    for i in range(mask.total_bits):
        if std.random.random_float64() < 0.5:
            mask.set(i, True)
    return mask


@always_inline
def get_random_int_list(size: Int, out vals: List[Int]):
    """Create a list of random bit indices.

    Args:
        size: The number of random indices to generate.
    """
    vals = List[Int](length=size, fill=0)
    std.random.randint(
        vals,
        0,
        Int(BitMask.total_bits - 1),
    )


def unique(l: List[Int], out result: List[Int]):
    var mask = Array[Bool, 256](fill=False)
    result = List[Int]()
    for v in l:
        if not mask[v]:
            mask[v] = True
            result.append(v)


@fieldwise_init
struct StringWriter(Movable, Writer):
    """Simple in-memory Writer implementation for functions."""

    var value: String

    def write_string(mut self, s: StringSlice):
        self.value += s


def write_to_string[T: Writable](value: T) -> String:
    """Writes a writable value into a string.

    Args:
        value: The writable value to write.

    Returns:
        The string representation produced by value.write_to(...).
    """
    var writer = StringWriter("")
    value.write_to(writer)
    return writer.value


@always_inline
def get_random_1_true_bitmasks(size: Int, out vals: List[BitMask]):
    vals = List[BitMask](capacity=size)
    for _ in range(size):
        vals.append(
            BitMask(
                Int(std.random.random_si64(0, Int64(BitMask.total_bits - 1)))
            )
        )


# ------ functions ------


def test_bit_mask() raises:
    var mask = BitMask(1, 2, 13, 27)

    assert_equal(4, mask.total_bits_set())

    assert_true(mask.get(1))
    assert_true(mask.get(2))
    assert_true(mask.get(13))
    assert_true(mask.get(27))

    assert_equal(
        String(mask),
        "[0110000000000100000000000001000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000]",
    )

    assert_false(mask.get(0))
    assert_false(mask.get(3))

    mask.set(0, True)
    mask.set(1, False)

    assert_true(mask.get(0))
    assert_false(mask.get(1))

    mask.flip(0)
    mask.flip(1)

    assert_false(mask.get(0))
    assert_true(mask.get(1))

    mask.flip(0)
    mask.flip(1)

    var other1 = BitMask(1, 2, 32)
    var other2 = BitMask(0, 2)

    assert_false(mask.contains(other1))
    assert_true(mask.contains(other2))

    mask.reset()
    assert_equal(0, mask.total_bits_set())

    mask = BitMask(1, 2, 13, 27)
    other1 = BitMask(1, 32)
    other2 = BitMask(0, 32)

    assert_true(mask.contains_any(other1))
    assert_false(mask.contains_any(other2))


def test_bit_mask_without_exclusive() raises:
    var mask = BitMask(1, 2, 13)
    assert_true(mask.matches(BitMask(1, 2, 13)))
    assert_true(mask.matches(BitMask(1, 2, 13, 27)))

    assert_false(mask.matches(BitMask(1, 2)))

    var excl = mask.exclusive()

    assert_true(excl.matches(BitMask(1, 2, 13)))
    assert_false(excl.matches(BitMask(1, 2, 13, 27)))
    assert_false(excl.matches(BitMask(1, 2, 3, 13)))


def test_bit_mask_eq() raises:
    var mask1 = get_random_bitmask()
    var mask2 = mask1

    assert_true(mask1 == mask2)

    mask2.flip(3)

    assert_false(mask1 == mask2)


def test_bit_mask_256() raises:
    for i in range(BitMask.total_bits):
        var mask = BitMask(i)
        assert_equal(1, mask.total_bits_set())
        assert_true(mask.get(i))

    var mask = BitMask()
    assert_equal(0, mask.total_bits_set())

    for i in range(mask.total_bits - 1):
        mask.set(i, True)
        assert_equal(i + 1, mask.total_bits_set())
        assert_true(mask.get(i))

    mask = BitMask(
        1,
        2,
        13,
        27,
        63,
        64,
        65,
    )

    assert_true(mask.contains(BitMask(1, 2, 63, 64)))
    assert_false(mask.contains(BitMask(1, 2, 63, 90)))

    assert_true(mask.contains_any(BitMask(6, 65, 111)))
    assert_false(mask.contains_any(BitMask(6, 66, 90)))


def test_bitmask_get_indices() raises:
    var size = 100
    std.random.seed(0)
    var indices = get_random_int_list(size)
    var mask = BitMask()
    for index in indices:
        mask.set(index, True)
    var unique_indices = unique(indices)

    assert_equal(len(unique_indices), len(mask.get_indices()))
    size = 0
    for idx in mask.get_indices():
        keep(idx)

    for value in unique_indices:
        var found = False
        for idx in mask.get_indices():
            if value == idx:
                found = True
                break
        assert_true(found, String(value) + " not found.")
        size += 1

    assert_equal(len(unique_indices), size)


def test_bitmask_get_indices_non_256() raises:
    """A non-default bitmask yields indices from all of its bytes."""
    comptime SmallBitMask = _BitMask[64]
    var mask = SmallBitMask(0, 7, 8, 31, 32, 63)
    var actual = List[Int]()
    for idx in mask.get_indices():
        actual.append(idx)

    assert_equal(6, len(actual))
    var expected: List[Int] = [0, 7, 8, 31, 32, 63]
    for expected_idx in expected:
        var found = False
        for idx in actual:
            if idx == expected_idx:
                found = True
                break
        assert_true(found, String(expected_idx) + " not found.")


def test_bitmask_writable() raises:
    var mask = BitMask(1, 2, 13, 27)
    assert_equal(String(mask), write_to_string(mask))

    var empty_mask = BitMask()
    assert_equal(String(empty_mask), write_to_string(empty_mask))


comptime functions = __functions_in_module()


def main() raises:
    TestSuite.discover_tests[functions]().run()
