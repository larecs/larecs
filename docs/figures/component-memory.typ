// Adapted from figs.typ archetype-memory and aos-soa-memory.
// Current descriptors own typed lifecycles; struct fields are not scalar columns.
#import "_style.typ": *
#diagram({
  panel(0, 0, 4.3, 2.0, [One physical store],
    [Mask · length · capacity\ revisions · incarnation\ IDs + column descriptors])
  panel(5.4, 0, 7.3, 2.0, [Component-ID-indexed descriptors],
    [Position: active → typed allocation\ Velocity: active → typed allocation\ Other: inactive → no allocation])
  arrow((4.3, -1), (5.4, -1))
  label((0, -2.8), [Separate allocations; matching indices identify one entity row], anchor: "west", bold: true)
  strip(0, -3.6, [Entity IDs], ([A], [B], [C], [spare]), paint: colors.panel)
  strip(6.1, -3.6, [Position column], ([x, y], [x, y], [x, y], [uninit.]))
  strip(6.1, -5.4, [Velocity column], ([dx, dy], [dx, dy], [dx, dy], [uninit.]), paint: colors.velocity)
  label((0, -5.0), [Live length: 3], anchor: "west")
  label((0, -5.65), [Illustrative capacity: 4], anchor: "west")
  label((6.3, -7.0), [Each cell contains a complete component struct. Spare slots hold no live value.], size: 8.5pt)
})
