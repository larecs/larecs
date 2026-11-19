from std.testing import TestSuite, assert_equal

from larecs._type_list import _TypeChecks
from larecs.component import (
    ComponentManager,
    constrain_components_unique,
    constrain_valid_components,
    constrain_device_safe_components,
)
from larecs.resource import Resources, constrain_device_safe_resources


def test_empty_type_lists() raises:
    """Checks vacuous checks and missing lookup on empty public type lists.

    Raises:
        Error: If a length assertion fails.
    """
    comptime assert constrain_components_unique[]()
    comptime assert not constrain_valid_components[]()
    comptime assert ComponentManager[].contains_components[]()
    comptime assert not ComponentManager[].contains_components[Int]()
    comptime assert Resources[].index_of[Int]() == -1
    comptime assert not Resources[].contains[Int]()
    comptime assert constrain_device_safe_components[]()
    comptime assert constrain_device_safe_resources[]()
    assert_equal(len(ComponentManager[].get_id_arr[]()), 0)
    assert_equal(len(Resources[]()), 0)


def test_type_identity_and_lookup() raises:
    """Checks ordering, separated duplicates, and missing types at compile time.

    Raises:
        Error: If a lookup assertion fails.
    """
    assert_equal(Resources[Int, Float32].index_of[Float32](), 1)
    comptime assert _TypeChecks[Int, Float32, String].unique()
    comptime assert not _TypeChecks[Int, Float32, Int].unique()
    comptime assert constrain_components_unique[Int, Float32, String]()
    comptime assert not constrain_components_unique[Int, Float32, Int]()
    comptime assert Resources[Int, Float32, Int].index_of[Int]() == 0
    comptime assert Resources[Int, Float32, Int].index_of[Float32]() == 1
    comptime assert Resources[Int, Float32, Int].index_of[String]() == -1
    comptime assert Resources[Int, Float32].contains[Int]()
    comptime assert not Resources[Int, Float32].contains[String]()
    comptime assert ComponentManager[Int, Float32].contains_components[
        Float32, Int, Float32
    ]()
    comptime assert not ComponentManager[Int, Float32].contains_components[
        Int, String
    ]()


def test_component_registry_duplicate_identity() raises:
    """Keeps last-registration IDs coherent with name-based membership.

    Raises:
        Error: If a registry ID assertion fails.
    """
    comptime Manager = ComponentManager[Int, Float32, Int]
    comptime assert Manager.contains_components[Int, Float32]()
    comptime assert (
        _TypeChecks[Int, Float32, Int].index_of[Int, by_name=True]() == 2
    )
    assert_equal(Int(Manager.get_id[Int]()), 2)
    assert_equal(Int(Manager.get_id[Float32]()), 1)
    assert_equal(Manager.get_type_name(2), reflect[Int].name())


def test_gpu_safety() raises:
    """Checks scalar transfer and owning types in each position of a type list.

    Raises:
        Error: If a GPU-safety assertion fails.
    """
    assert_equal(constrain_device_safe_components[Int32, String](), False)
    assert_equal(constrain_device_safe_resources[Int32, String](), False)
    comptime assert constrain_device_safe_components[Int32, Float32]()
    comptime assert constrain_device_safe_resources[Int32, Float32]()
    comptime assert not constrain_device_safe_components[String]()
    comptime assert not constrain_device_safe_resources[String]()
    comptime assert not constrain_device_safe_components[String, Int32]()
    comptime assert not constrain_device_safe_resources[String, Int32]()
    comptime assert not constrain_device_safe_components[Int32, String]()
    comptime assert not constrain_device_safe_resources[Int32, String]()
    comptime assert not constrain_device_safe_components[List[Int]]()
    comptime assert not constrain_device_safe_resources[List[Int]]()


def main() raises:
    """Runs type-list regressions.

    Raises:
        Error: If a test assertion fails.
    """
    TestSuite.discover_tests[__functions_in_module()]().run()
