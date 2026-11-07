// Adapted from master-thesis/figs.typ: device-memory.
// Current packing/scatter and access declarations; unselected gaps stay on host.
#import "_style.typ": *
#diagram({
  label((0, 1.1), [Host physical stores], anchor: "west", bold: true)
  label((8, 1.1), [Packed device columns], anchor: "west", bold: true)
  panel(0, 0, 3.4, 1.4, [A selected range], [Position + Velocity\ rows a, b])
  panel(0, -2, 3.4, 1.4, [B selected range], [Position + Velocity\ rows c, d])
  panel(4.2, -.7, 2.4, 2, [Pack], [Readable\ spans only])
  arrow((3.4, -.7), (4.2, -1.2))
  arrow((3.4, -2.7), (4.2, -2.2))
  strip(8, 0, [Position: read + write], ([a], [b], [c], [d]))
  strip(8, -1.6, [Velocity: read], ([a], [b], [c], [d]), paint: colors.velocity)
  arrow((6.6, -1.2), (7.9, -.3))
  arrow((6.6, -2.2), (7.9, -1.9))
  panel(0, -3.9, 3.4, 1.1, [Other rows], [Unselected: untouched])
  panel(8, -3.2, 4.4, 1.2, [move], [One launch across matching rows], paint: colors.output)
  arrow((10.2, -2.4), (10.2, -3.2))
  panel(8, -5.3, 4.4, 1.2, [Synchronize → publish], [Download written Position only], paint: colors.output)
  arrow((10.2, -4.4), (10.2, -5.3))
  panel(0, -5.7, 3.4, 1.2, [Scatter to A/B], [Original Position ranges], paint: colors.output)
  arrow((8, -6.3), (3.4, -6.3))
  label((6.2, -7.7), [Write-only components skip upload; resources/captures bind separately.], size: 8.5pt)
})
