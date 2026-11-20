// Adapted from master-thesis/figs.typ: spatial-ordering and spatial-grouping.
// One growable store per cluster; all columns move with entity identities.
#import "_style.typ": *
#diagram({
  label((0, 1.1), [Row ordering (default)], anchor: "west", bold: true)
  strip(0, 0, [Before maintenance], ([A:k1], [B:k0], [C:k1], [D:k0]),
    paints: (colors.position, colors.cluster, colors.position, colors.cluster))
  arrow((5.0, -.3), (6.2, -.3))
  strip(6.8, 0, [After: ascending keys], ([B:k0], [D:k0], [A:k1], [C:k1]),
    paints: (colors.cluster, colors.cluster, colors.position, colors.position))
  label((5.8, -1.4), [One physical store; equal keys contiguous; ties unspecified.], size: 8.5pt)
  label((0, -2.5), [Growable partitions (opt in)], anchor: "west", bold: true)
  panel(0, -3, 3.6, 1.3, [Staging], [D newly created\ classified at boundary])
  panel(4.4, -3, 3.2, 1.3, [Cluster k0], [B already placed], paint: colors.cluster)
  panel(8.4, -3, 3.2, 1.3, [Cluster k1], [A, C already placed])
  arrow((1.8, -4.3), (1.8, -5.0))
  label((2.1, -4.65), [maintain], anchor: "west", size: 8.5pt)
  panel(0, -5.1, 3.6, 1.3, [Staging empty], [Row allocations released])
  panel(4.4, -5.1, 3.2, 1.3, [Cluster k0], [B, D\ capacity doubles], paint: colors.cluster)
  panel(8.4, -5.1, 3.2, 1.3, [Cluster k1], [A, C\ separate allocation])
  arrow((3.6, -3.65), (4.4, -5.1))
  label((5.8, -7.2), [Keys group locality; exact neighbors still need cell/distance checks.], size: 8.5pt)
})
