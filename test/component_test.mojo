from std.sys import size_of
from std.testing import *

from larecs.component import (
    ComponentType,
    ComponentManager,
    constrain_components_unique,
    constrain_valid_components,
)


@fieldwise_init
struct TestLargerComponent(ComponentType & ImplicitlyCopyable):
    var x: Float64
    var y: Float64
    var z: Float64


@fieldwise_init
struct TestPosition(ComponentType & ImplicitlyCopyable):
    var x: Float64
    var y: Float64


@fieldwise_init
struct TestVelocity(ComponentType & ImplicitlyCopyable):
    var dx: Float64
    var dy: Float64


comptime component_manager = ComponentManager[
    TestLargerComponent, TestPosition, TestVelocity
]


def test_constrain_components_unique() raises:
    assert_true(constrain_components_unique[TestPosition]())
    assert_true(constrain_components_unique[TestPosition, TestVelocity]())
    assert_true(
        constrain_components_unique[
            TestPosition, TestVelocity, TestLargerComponent
        ]()
    )
    assert_false(constrain_components_unique[TestPosition, TestPosition]())


def test_constrain_valid_components() raises:
    assert_true(constrain_valid_components[TestPosition]())
    assert_true(constrain_valid_components[TestPosition, TestVelocity]())
    assert_false(constrain_valid_components[TestPosition, TestPosition]())
    assert_false(constrain_valid_components[]())


def test_component_manager_get_id() raises:
    assert_equal(Int(component_manager.get_id[TestLargerComponent]()), 0)
    assert_equal(Int(component_manager.get_id[TestPosition]()), 1)
    assert_equal(Int(component_manager.get_id[TestVelocity]()), 2)


def test_component_manager_get_id_arr() raises:
    comptime assert component_manager.contains_components[
        TestPosition, TestVelocity
    ](), "Component types not in component manager"
    comptime assert constrain_components_unique[
        TestPosition, TestVelocity
    ](), "Component types not unique"
    var ids = component_manager.get_id_arr[TestPosition, TestVelocity]()

    assert_equal(len(ids), 2)
    assert_equal(Int(ids[0]), 1)
    assert_equal(Int(ids[1]), 2)


comptime functions = __functions_in_module()


def main() raises:
    TestSuite.discover_tests[functions]().run()
