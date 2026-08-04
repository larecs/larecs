# from collections import Dict
from std.collections.check_bounds import check_bounds

from tracy import Zone

from .bitmask import BitMask


comptime NodeDataType = KeyElement & Copyable & Deinitable
"""The trait that the data stored in the graph nodes must conform to."""


@fieldwise_init
struct Node[DataType: NodeDataType](ImplicitlyCopyable):
    """Node in a BitMaskGraph.

    Parameters:
        DataType: The type of the value stored in the node.
    """

    # The index indicating a non-established link.
    comptime null_index = -1
    """Sentinel index for a neighbour link that has not been created."""

    # The value stored in the node.
    var value: Self.DataType
    """The value stored for this graph node."""

    # The indices of the neighbouring nodes.
    # The node at index i difffers from the
    # current node by the i-th bit.
    var neighbours: Array[Int, 256]
    """Neighbour node indices keyed by the bit that differs."""

    # The mask of the node.
    var bit_mask: BitMask
    """The bitmask represented by this graph node."""

    def __init__(out self, bit_mask: BitMask, var value: Self.DataType):
        """Initializes the node with the given mask and value.

        Args:
            bit_mask: The bit mask of the node.
            value:    The value stored in the node.
        """
        with Zone(
            function_name=(
                "Node.__init__(bit_mask: BitMask, var value: Self.DataType)"
            )
        ):
            self.value = value^
            self.neighbours = Array[Int, 256](fill=Self.null_index)
            self.bit_mask = bit_mask

    def __init__(out self, *, copy: Self):
        """Copies a graph node.

        Args:
            copy: The node to copy.
        """
        with Zone(function_name="Node.__init__(copy: Self)"):
            self = Self(copy.bit_mask, copy.value.copy())


struct BitMaskGraph[
    DataType: NodeDataType,
    //,
    null_value: DataType,
](Copyable, Movable):
    """A graph where each node is identified by a BitMask.

    The graph is intended to be used for fast lookup of data
    identified by bitmasks based on a known starting point
    differing only in a few bits from the sought-after node.

    Nodes that differ by exactly one bit are connected via edges.
    Edges are constructed upon first use.

    Parameters:
        DataType:   The type of the value stored in the nodes.
        null_value: The place holder stored in nodes by default.
    """

    # The node index indicating a non-established link.
    comptime null_index = Node[Self.DataType].null_index
    """Sentinel index for graph links that have not been established."""

    # The list of nodes in the graph.
    var _nodes: List[Node[Self.DataType]]
    """All graph nodes, indexed by node ID."""

    # A mapping for random lookup of nodes by their mask.
    # Used for slow lookup of nodes.
    var _map: Dict[BitMask, Int]
    """Lookup table from bitmask to node index."""

    def __init__(out self, var first_value: Self.DataType = Self.null_value):
        """Initializes the graph.

        Args:
            first_value: The value stored in the first node,
                         corresponding to an empty bitmask.
        """
        with Zone(
            function_name=(
                "BitMaskGraph.__init__(var first_value: Self.DataType)"
            )
        ):
            self._nodes = List[Node[Self.DataType]]()
            self._map = Dict[BitMask, Int]()
            _ = self.add_node(BitMask(), first_value^)

    @always_inline
    def add_node(
        mut self,
        node_mask: BitMask,
        var value: Self.DataType = Self.null_value,
    ) -> Int:
        """Adds a node to the graph.

        Args:
            node_mask: The mask of the node.
            value:     The value stored in the node.

        Returns:
            The index of the added node.
        """
        with Zone(
            function_name=(
                "BitMaskGraph.add_node(node_mask: BitMask, var value:"
                " Self.DataType)"
            )
        ):
            var new_node_idx = len(self._nodes)
            self._map[node_mask] = new_node_idx
            self._nodes.insert(new_node_idx, Node(node_mask, value^))
            return new_node_idx

    @always_inline
    def create_link(mut self, from_node_index: Int, changed_bit: Int) -> Int:
        """Creates a link between two nodes.

        Note: this does not check whether the link is already established.

        Args:
            from_node_index: The index of the node from which the link is created.
            changed_bit:     The index of the bit that differs between the nodes.

        Returns:
            The index of the node to which the link is created.
        """
        with Zone(
            function_name=(
                "BitMaskGraph.create_link(from_node_index: Int, changed_bit:"
                " Int)"
            )
        ):
            check_bounds(from_node_index, len(self._nodes))
            check_bounds(changed_bit, BitMask.total_bits)

            new_mask = self._nodes[from_node_index].bit_mask
            new_mask.flip(changed_bit)
            optional_to_index = self._map.get(new_mask)
            if optional_to_index:
                to_node_index = optional_to_index.value()
            else:
                to_node_index = self.add_node(new_mask)

            self._nodes[from_node_index].neighbours[changed_bit] = to_node_index
            self._nodes[to_node_index].neighbours[changed_bit] = from_node_index

            return to_node_index

    @always_inline
    def get_node_index[
        size: Int
    ](
        mut self,
        different_bits: Array[Int, size],
        start_node_index: Int = 0,
    ) -> Int:
        """Returns the index of the node differing from the start node
        by the given indices.

        If necessary, creates a new node and links it to the start node.

        Parameters:
            size:             The number of indices.

        Args:
            different_bits:   The indices of the bits that differ between the nodes.
            start_node_index: The index of the start node.

        Returns:
            The index of the node differing from the start node by the given indices.
        """
        with Zone(
            function_name=(
                "BitMaskGraph.get_node_index[size: Int](different_bits:"
                " Array[Int, size], start_node_index: Int)"
            )
        ):
            comptime assert 0 <= size, "Size must be non-negative"
            check_bounds(start_node_index, len(self._nodes))

            var current_node = start_node_index

            comptime for i in range(size):
                var differing_bit = different_bits[i]
                check_bounds(differing_bit, BitMask.total_bits)

                var next_node = self._nodes[current_node].neighbours[
                    differing_bit
                ]

                if next_node == Self.null_index:
                    next_node = self.create_link(current_node, differing_bit)
                current_node = next_node
            return current_node

    @always_inline
    def get_node_mask(
        self: Self, node_index: Int
    ) -> ref[self._nodes[node_index].bit_mask] BitMask:
        """Returns the mask of the node at the given index.

        Args:
            node_index: The index of the node.

        Returns:
            The mask of the node.
        """
        with Zone(function_name="BitMaskGraph.get_node_mask(node_index: Int)"):
            check_bounds(node_index, len(self._nodes))
            return self._nodes[node_index].bit_mask

    @always_inline
    def __getitem__(
        ref self: Self, node_index: Int
    ) -> ref[self._nodes[node_index].value] Self.DataType:
        """Returns the value stored in the node at the given index.

        Args:
            node_index: The index of the node.
        """
        with Zone(function_name="BitMaskGraph.__getitem__(node_index: Int)"):
            check_bounds(node_index, len(self._nodes))
            return self._nodes[node_index].value

    @always_inline
    def has_value(self: Self, node_index: Int) -> Bool:
        """Returns whether the node at the given index has a value.

        Args:
            node_index: The index of the node.
        """
        with Zone(function_name="BitMaskGraph.has_value(node_index: Int)"):
            check_bounds(node_index, len(self._nodes))
            return self[node_index] != materialize[Self.null_value]()
