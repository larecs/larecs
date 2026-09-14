from std.testing import *
from std.sys import size_of

from larecs.test_utils import *
from larecs.static_optional import StaticOptional


def test_comptime_optional_init() raises:
    var opt = StaticOptional[Int, False]()
    assert_false(opt.has_value)
    _ = opt._value
    var l: List[Int] = [42]
    var opt_with_value: StaticOptional[List[Int], True] = l^
    assert_true(opt_with_value.has_value)
    assert_equal(opt_with_value[][0], 42)


def test_comptime_optional_copy() raises:
    var opt_with_value = StaticOptional(42)
    var opt_copy = opt_with_value.copy()
    assert_true(opt_copy.has_value)
    assert_equal(opt_copy[], 42)
    var opt_without_value = StaticOptional[Int, False]()
    var opt_copy_without = opt_without_value.copy()
    _ = opt_copy_without._value


def test_comptime_optional_move_del() raises:
    def factory(
        var val: MemTestStruct[
            MutUnsafeAnyOrigin, MutUnsafeAnyOrigin, MutUnsafeAnyOrigin
        ],
        out result: StaticOptional[
            MemTestStruct[
                MutUnsafeAnyOrigin, MutUnsafeAnyOrigin, MutUnsafeAnyOrigin
            ],
            True,
        ],
    ):
        result = type_of(result)(val^)

    test_copy_move_del[factory](init_moves=1, move_moves=1)


def test_comptime_optional_value() raises:
    var opt_with_value = StaticOptional[Int, True](42)
    assert_equal(opt_with_value[], 42)


def test_comptime_optional_size() raises:
    assert_equal(size_of[StaticOptional[UInt16, True]](), 2)
    assert_equal(size_of[StaticOptional[UInt16, False]](), 0)


@fieldwise_init
struct EmbeddedFalseOptional(Copyable, Movable):
    """Struct used to verify absent optional storage inside another struct.

    Raises:
        No runtime exceptions.

    Returns:
        A struct containing an absent `StaticOptional`.
    """

    var before: UInt8
    var optional: StaticOptional[UInt64, False]
    var after: UInt8


def test_static_optional_embedded_size() raises:
    """Verify absent optional storage does not add payload bytes in a struct.

    Raises:
        An assertion failure if absent storage changes the embedded layout.

    """

    assert_equal(size_of[EmbeddedFalseOptional](), 2)


def optional_argument_application[
    has_value: Bool = False
](opt: StaticOptional[Int, has_value] = None) -> Bool:
    return opt.has_value


def test_optional_argument_application() raises:
    assert_false(optional_argument_application[False]())
    assert_true(optional_argument_application[True](123))


def test_or_else() raises:
    var opt = StaticOptional[Int, False]()
    assert_equal(opt.or_else(42), 42)
    var opt2 = StaticOptional(10)
    assert_equal(opt2.or_else(42), 10)
    var l1 = List([1, 2, 3])
    var opt3 = StaticOptional[List[Int], False]()
    assert_equal(Int(Pointer(to=l1)), Int(Pointer(to=opt3.or_else(l1))))


comptime functions = Tuple(
    test_comptime_optional_init,
    test_comptime_optional_copy,
    test_comptime_optional_move_del,
    test_comptime_optional_value,
    test_comptime_optional_size,
    test_static_optional_embedded_size,
    test_optional_argument_application,
    test_or_else,
)


def main() raises:
    var suite = TestSuite.discover_tests[functions]()
    suite^.run()
