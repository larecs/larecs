from tracy import Zone

from .bitmask import _BitMask


# Filter is the interface for logic filters.
# Filters are required to query entities using [Storage.Query].
#
# See [BitMask], [MaskFilter] anf [RelationFilter] for basic filters.
# For type-safe generics queries, see package [github.com/mlange-42/arche/generic].
# For advanced filtering, see package [github.com/mlange-42/arche/filter].

# type Filter interface:
#     # matches the filter against a mask, i.e. a component composition.
#     matches(bits BitMask): Bool


@fieldwise_init
struct MaskFilter[total_bits: Int]:
    """MaskFilter is a filter for including and excluding certain components."""

    comptime bitmask = _BitMask[Self.total_bits]
    """The concrete bitmask type matched by this filter."""

    var include: Self.bitmask  # Components to include.
    """Component bits that must be present."""
    var exclude: Self.bitmask  # Components to exclude.
    """Component bits that must be absent."""

    def matches(self, bits: Self.bitmask) -> Bool:
        """Matches the filter against a mask."""
        with Zone(function_name="MaskFilter.matches(bits: Self.bitmask)"):
            return bits.contains(self.include) and (
                self.exclude.is_zero() or not bits.contains_any(self.exclude)
            )


# # RelationFilter is a [Filter] for a [Relation] target, in addition to components.
# #
# # See [Relation] for details and examples.
# struct RelationFilter:
#     Filter Filter # Components filter.
#     Target Entity # Relation target entity.

# # NewRelationFilter creates a new [RelationFilter].
# # It is a [Filter] for a [Relation] target, in addition to components.
# def NewRelationFilter(filter Filter, target Entity) RelationFilter:
#     return RelationFilter{
#         Filter: filter,
#         Target: target,


# # matches the filter against a mask.
# def (f *RelationFilter) matches(bits BitMask): Bool:
#     return f.Filter.matches(bits)

# # CachedFilter is a filter that is cached by the world.
# #
# # Create a cached filter from any other filter using [Cache.Register].
# # For details on caching, see [Cache].
# type CachedFilter struct:
#     filter Filter
#     id     uint32

# # matches the filter against a mask.
# def (f *CachedFilter) matches(bits BitMask): Bool:
#     return f.filter.matches(bits)
