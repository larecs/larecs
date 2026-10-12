from std.testing import *

from larecs.gpu_launch import BLOCK_SIZE, gpu_grid_dim


def test_block_size_fills_simd_groups() raises:
    assert_equal(BLOCK_SIZE % 64, 0)


def test_grid_dim_covers_every_row() raises:
    assert_equal(gpu_grid_dim(0, 0), 0)
    assert_equal(gpu_grid_dim(1, 0), 1)
    assert_equal(gpu_grid_dim(BLOCK_SIZE, 0), 1)
    assert_equal(gpu_grid_dim(BLOCK_SIZE + 1, 0), 2)
    assert_equal(gpu_grid_dim(100 * BLOCK_SIZE, 0), 100)


def test_grid_dim_is_capped() raises:
    assert_equal(gpu_grid_dim(100 * BLOCK_SIZE, 8), 8)
    assert_equal(gpu_grid_dim(BLOCK_SIZE + 1, 8), 2)
    assert_equal(gpu_grid_dim(0, 8), 0)


comptime functions = __functions_in_module()


def main() raises:
    TestSuite.discover_tests[functions]().run()
