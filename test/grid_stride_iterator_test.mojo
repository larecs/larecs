# SKIP_ASAN

from max.gpu.host import DeviceContext, DevicePointer
from std.atomic import Atomic
from std.builtin.device_passable import DevicePassable, DeviceTypeEncoder
from std.gpu import global_idx
from std.sys import has_accelerator


comptime LENGTH = 255
comptime BLOCK_SIZE = 32
comptime GRID_DIM = 2
comptime THREAD_COUNT = BLOCK_SIZE * GRID_DIM


@fieldwise_init
struct DeviceTraceContext(Copyable, RegisterPassable):
    """Device-side view used to verify grid-stride row ownership."""

    var length: Int32
    var thread_count: Int32
    var owner: Pointer[Int32, MutUntrackedOrigin]
    var visits: Pointer[Int32, MutUntrackedOrigin]


@fieldwise_init
struct HostTraceContext(Copyable, DevicePassable, RegisterPassable):
    """Device-passable host view for the grid-stride trace kernel."""

    comptime device_type = DeviceTraceContext

    var length: Int32
    var thread_count: Int32
    var owner: DevicePointer[
        mut=True, dtype=DType.int32, origin=MutUntrackedOrigin
    ]
    var visits: DevicePointer[
        mut=True, dtype=DType.int32, origin=MutUntrackedOrigin
    ]

    @staticmethod
    def get_type_name() -> String:
        """Returns the device-side diagnostic type name."""
        return "DeviceTraceContext"

    def _to_device_type[
        Encoder: DeviceTypeEncoder
    ](
        self,
        mut encoder: Encoder,
        target: Pointer[mut=True, T=NoneType, origin=_],
    ):
        """Encodes the host device-buffer views for the trace kernel.

        Parameters:
            Encoder: The device type encoder used for dispatch.

        Args:
            encoder: The encoder receiving the context fields.
            target: The device-side target for the encoded context.
        """
        encoder.encode_fields[
            StructType=Self, DeviceStructType=Self.device_type
        ](self, target)


def trace_grid_stride(context: DeviceTraceContext):
    """Records the thread owner and visit count for every assigned row.

    Args:
        context: The device buffers and dimensions used by the trace.
    """
    var row = Int32(global_idx.x)
    while row < context.length:
        context.owner[unsafe_offset=Int(row)] = Int32(global_idx.x)
        _ = Atomic.fetch_add(
            context.visits.unsafe_offset(Int(row)), 1
        )
        row += context.thread_count


def test_grid_stride_assigns_unique_chunks() raises:
    """Verifies that every row is visited once by its expected thread."""
    comptime if not has_accelerator():
        return

    var device = DeviceContext()
    var owner = device.create_buffer_sync[DType.int32](LENGTH)
    var visits = device.create_buffer_sync[DType.int32](LENGTH)
    owner.enqueue_fill(-1)
    visits.enqueue_fill(0)

    var context = HostTraceContext(
        length=Int32(LENGTH),
        thread_count=Int32(THREAD_COUNT),
        owner=rebind[
            DevicePointer[
                mut=True, dtype=DType.int32, origin=MutUntrackedOrigin
            ]
        ](DevicePointer(owner)),
        visits=rebind[
            DevicePointer[
                mut=True, dtype=DType.int32, origin=MutUntrackedOrigin
            ]
        ](DevicePointer(visits)),
    )

    device.enqueue_function[trace_grid_stride](
        context,
        grid_dim=GRID_DIM,
        block_dim=BLOCK_SIZE,
    )
    device.synchronize()

    var host_owner = List[Int32](length=LENGTH, fill=-1)
    var host_visits = List[Int32](length=LENGTH, fill=0)
    owner.enqueue_copy_to(host_owner.unsafe_ptr())
    visits.enqueue_copy_to(host_visits.unsafe_ptr())
    device.synchronize()

    for row in range(LENGTH):
        assert host_owner[row] == Int32(row % THREAD_COUNT)
        assert host_visits[row] == 1


def main() raises:
    """Runs the grid-stride iterator verification test."""
    test_grid_stride_assigns_unique_chunks()
