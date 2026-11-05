"""GPU kernel launch geometry shared by device storage and system execution."""

from max.gpu.host import DeviceAttribute, DeviceContext
from std.math import ceildiv

from .debug_utils import debug_warn


comptime BLOCK_SIZE = 2**8
"""Number of GPU threads per block used when launching kernels.

A multiple of every common SIMD width (32 on NVIDIA and Apple, 64 on AMD),
so no warp/wavefront of a full block runs partially empty, and large enough
that the per-multiprocessor block limit does not cap occupancy.
"""


def gpu_grid_dim(length: Int, max_grid_dim: Int) -> Int:
    """Returns the number of blocks to launch for ``length`` matching rows.

    Launches one thread per row, but never more blocks than
    ``max_grid_dim``. Above that cap, the threads of the launch cover the
    remaining rows through the grid-stride loop of `EntityAccessorIterator`,
    so the grid stays at roughly one wave of blocks instead of scheduling a
    block per `BLOCK_SIZE` rows.

    Args:
        length: The number of rows the kernel processes.
        max_grid_dim: The maximum number of blocks to launch. A value
            below ``1`` disables the cap.

    Returns:
        The grid dimension; ``0`` if ``length`` is ``0``.
    """
    var grid_dim = ceildiv(length, BLOCK_SIZE)
    if max_grid_dim > 0:
        return min(grid_dim, max_grid_dim)
    return grid_dim


def max_resident_blocks(device_context: DeviceContext) -> Int:
    """Returns a thread-based upper bound on resident `BLOCK_SIZE` blocks.

    This is the number of multiprocessors times the number of blocks of
    `BLOCK_SIZE` threads each one's thread limit allows, i.e. at most one
    full wave. A kernel's register and shared-memory use can make fewer
    blocks resident at once; this bound does not account for them.

    Args:
        device_context: The device to query.

    Returns:
        The upper bound on resident blocks, or ``0`` if the device does not
        report the required attributes.
    """
    try:
        var multiprocessors = device_context.get_attribute(
            DeviceAttribute.MULTIPROCESSOR_COUNT
        )
        var threads_per_multiprocessor = device_context.get_attribute(
            DeviceAttribute.MAX_THREADS_PER_MULTIPROCESSOR
        )
        return multiprocessors * max(
            threads_per_multiprocessor // BLOCK_SIZE, 1
        )
    except e:
        debug_warn(
            t"Could not query the device's resident"
            t" block count, kernel grids will not be capped: {String(e)}"
        )
        return 0
