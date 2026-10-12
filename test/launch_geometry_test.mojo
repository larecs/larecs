"""Host tests for GPU kernel launch geometry."""


from std.testing import *

from larecs.gpu_launch import BLOCK_SIZE, gpu_grid_dim


def test_block_size_fills_simd_groups() raises:
    """`BLOCK_SIZE` is a multiple of every common SIMD width.

    Raises:
        Error: If the assertion fails.
    """
    assert_equal(BLOCK_SIZE % 64, 0)


def test_grid_dim_covers_every_row() raises:
    """Uncapped grids launch one thread per row, rounded up to whole blocks.

    Raises:
        Error: If an assertion fails.
    """
    assert_equal(gpu_grid_dim(0, 0), 0)
    assert_equal(gpu_grid_dim(1, 0), 1)
    assert_equal(gpu_grid_dim(BLOCK_SIZE, 0), 1)
    assert_equal(gpu_grid_dim(BLOCK_SIZE + 1, 0), 2)
    assert_equal(gpu_grid_dim(100 * BLOCK_SIZE, 0), 100)


def test_grid_dim_is_capped() raises:
    """Capped grids never exceed the cap and stay empty for zero rows.

    Raises:
        Error: If an assertion fails.
    """
    assert_equal(gpu_grid_dim(100 * BLOCK_SIZE, 8), 8)
    assert_equal(gpu_grid_dim(BLOCK_SIZE + 1, 8), 2)
    assert_equal(gpu_grid_dim(0, 8), 0)


comptime functions = __functions_in_module()


def main() raises:
    """Runs launch geometry tests.

    Raises:
        Error: If any discovered test fails.
    """
    TestSuite.discover_tests[functions]().run()
