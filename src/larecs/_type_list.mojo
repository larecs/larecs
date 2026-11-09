"""Internal type-list checks shared by component and resource APIs.

Component registries identify types by reflected name; resource lists use
exact type identity. Keep that distinction explicit at each call site.
This module must not import component or resource modules.
"""


struct _TypeChecks[*Ts: Copyable & Deinitable]:
    """Compile-time operations on storage-compatible types.

    Parameters:
        Ts: The types to inspect, in declaration order.
    """

    @staticmethod
    @always_inline
    def index_of[T: Copyable & Deinitable, by_name: Bool = False]() -> Int:
        """Finds a type using the requested identity rule.

        Parameters:
            T: The type to find.
            by_name: Compare reflected names instead of exact types.

        Returns:
            The first exact-type index or last name-matching index, or -1
            if absent. Name lookup matches component registry overwrite semantics.
        """
        comptime if by_name:
            comptime indices = Self._name_indices()
            comptime index = indices.get(reflect[T].name())
            comptime if index:
                return index.unsafe_value()
            return -1
        else:
            comptime for i in range(len(Self.Ts)):
                comptime if Self.Ts[i] == T:
                    return i
            return -1

    @staticmethod
    @always_inline
    def unique[by_name: Bool = False]() -> Bool:
        """Checks that no two types have the same identity.

        Parameters:
            by_name: Compare reflected names instead of exact types.

        Returns:
            True for an empty list or a list without duplicate identities.
        """
        comptime if by_name:
            comptime indices = Self._name_indices()
            comptime count = len(indices)
            return count == len(Self.Ts)
        else:
            comptime for i in range(len(Self.Ts)):
                comptime for j in range(i):
                    comptime if Self.Ts[i] == Self.Ts[j]:
                        return False
            return True

    @staticmethod
    def _name_indices(out indices: Dict[String, Int]):
        """Builds the shared index for reflected-name identity checks.

        Returns:
            The output mapping ``indices``, with the last index for each name.
        """
        indices = {}
        comptime for i in range(len(Self.Ts)):
            indices[reflect[Self.Ts[i]].name()] = i

    @staticmethod
    @always_inline
    def device_safe() -> Bool:
        """Checks that every type supports raw-byte GPU transfer.

        Returns:
            True when every type is TrivialRegisterPassable, including an
            empty list.
        """
        comptime for i in range(len(Self.Ts)):
            comptime if not conforms_to(Self.Ts[i], TrivialRegisterPassable):
                return False
        return True
