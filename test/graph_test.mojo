from std.testing import *
from larecs.bitmask import BitMask
from larecs.graph import Node, BitMaskGraph


def test_node_initialization() raises:
    bit_mask = BitMask(1, 3, 4)
    value = 42
    node = Node(bit_mask, value)
    assert_equal(node.value, value)
    assert_equal(node.bit_mask, bit_mask)
    assert_equal(len(node.neighbours), 256)
    for i in range(256):
        assert_equal(node.neighbours[i], node.null_index)


def test_graph_initialization() raises:
    graph = BitMaskGraph[-1]()
    assert_equal(len(graph._nodes), 1)
    assert_equal(len(graph._map), 1)


def test_add_node() raises:
    graph = BitMaskGraph[-1]()
    bit_mask = BitMask(0, 2)
    value = 42
    node_index = graph.add_node(bit_mask, value)
    assert_equal(node_index, 1)
    assert_equal(len(graph._nodes), 2)
    assert_equal(graph._nodes[1].value, value)
    assert_equal(graph._nodes[1].bit_mask, bit_mask)
    assert_equal(graph._map[bit_mask], 1)


def test_getitem() raises:
    comptime null_value = -1
    graph = BitMaskGraph[null_value]()
    bit_mask = BitMask(0, 2)
    value = 42
    node_index = graph.add_node(bit_mask, value)
    assert_equal(graph[node_index], value)
    bit_mask = BitMask(0, 2, 3)
    node_index = graph.add_node(bit_mask)
    assert_equal(graph[node_index], null_value)


def test_create_link() raises:
    comptime null_value = -1
    graph = BitMaskGraph[null_value]()
    var bitmask_root = BitMask()
    var bm_root_index = 0

    assert_equal(graph._nodes[bm_root_index].bit_mask, bitmask_root)
    assert_equal(graph._nodes[bm_root_index].value, null_value)

    var graph_size = len(graph._nodes)
    assert_equal(graph_size, 1)

    var bit_mask02 = BitMask(0, 2)
    var bm02_index = graph.add_node(bit_mask02, 42)
    assert_equal(bm02_index, graph_size)
    assert_equal(graph._nodes[bm02_index].bit_mask, bit_mask02)
    assert_equal(graph._nodes[bm02_index].value, 42)

    graph_size = len(graph._nodes)
    assert_equal(graph_size, 2)

    assert_equal(graph._nodes[bm02_index].neighbours[0], graph.null_index)
    assert_equal(graph._nodes[bm02_index].neighbours[2], graph.null_index)

    # This should create a new node with BitMask(0)
    var bm0_index = graph.create_link(bm_root_index, 0)
    assert_equal(bm0_index, graph_size)
    assert_equal(graph._nodes[bm0_index].bit_mask, BitMask(0))
    assert_equal(graph._nodes[bm0_index].value, null_value)

    graph_size = len(graph._nodes)
    assert_equal(graph_size, 3)

    assert_equal(graph._nodes[bm_root_index].neighbours[0], bm0_index)
    assert_equal(graph._nodes[bm0_index].neighbours[0], bm_root_index)
    # Check that the neighbour for the second bit is still null
    assert_equal(graph._nodes[bm0_index].neighbours[2], graph.null_index)

    # This should not create a new node, as node with BitMask(0,2) already exists
    var to_index = graph.create_link(bm0_index, 2)
    assert_equal(to_index, bm02_index)

    assert_equal(graph_size, len(graph._nodes))

    assert_equal(graph._nodes[bm0_index].neighbours[2], bm02_index)
    assert_equal(graph._nodes[bm02_index].neighbours[2], bm0_index)
    # Check that the neighbour for the zero-th bit is still null
    assert_equal(graph._nodes[bm02_index].neighbours[0], graph.null_index)


def test_get_node_index() raises:
    graph = BitMaskGraph[-1]()
    bit_mask2 = BitMask(0, 2)
    bit_mask1 = BitMask(0)
    different_bits: Array[Int, 2] = [0, 2]
    node_index = graph.get_node_index(different_bits)
    assert_equal(node_index, 2)
    assert_equal(graph._nodes[1].bit_mask, bit_mask1)
    assert_equal(graph._nodes[node_index].bit_mask, bit_mask2)

    different_bits: Array[Int, 2] = [5, 5]
    assert_equal(graph.get_node_index(different_bits), 0)
    assert_equal(graph._nodes[3].bit_mask, BitMask(5))


def test_get_node_mask() raises:
    graph = BitMaskGraph[-1]()
    bit_mask = BitMask(0, 2)
    node_index = graph.add_node(bit_mask, 42)
    assert_equal(graph.get_node_mask(node_index), bit_mask)


struct S:
    var l: List[Node[Int]]

    def __init__(out self):
        self.l = List[Node[Int]]()
        self.add(BitMask(), -1)

    def add(mut self, var node_mask: BitMask, var value: Int):
        self.l.append(Node(node_mask, value))


def test_has_value() raises:
    graph = BitMaskGraph[-1]()
    bit_mask = BitMask(0, 2)
    value = 42
    node_index = graph.add_node(bit_mask, value)
    assert_equal(graph.has_value(node_index), True)
    assert_equal(graph.has_value(0), False)


comptime functions = __functions_in_module()


def main() raises:
    TestSuite.discover_tests[functions]().run()
