// Adapted from figs.typ archetype-add-component; current canonical staging destination.
// Retained values move; new values initialize; source tail and entity locations repair.
#import "_style.typ": *
#diagram({
  label((0, .9), [Before: add Velocity to B], anchor: "west", bold: true)
  strip(0, 0, [Source: Position], ([A], [B], [C]))
  strip(7.1, 0, [Destination: Position + Velocity], ([D], [spare]), paint: colors.velocity)
  panel(0, -1.6, 3.4, 1.9, [1. Validate], [Retain / remove\ replace / add\ validate first])
  panel(4.3, -1.6, 3.4, 1.9, [2. Transfer B], [Move Position\ initialize Velocity\ append B at row 1], paint: colors.output)
  panel(8.6, -1.6, 3.4, 1.9, [3. Fill source hole], [C: row 2 → row 1\ shorten source\ repair locations])
  arrow((3.4, -2.55), (4.3, -2.55))
  arrow((7.7, -2.55), (8.6, -2.55))
  label((0, -4.4), [After: identities unchanged], anchor: "west", bold: true)
  strip(0, -5.1, [Source: Position], ([A], [C]))
  strip(7.1, -5.1, [Destination: Position + Velocity], ([D], [B]), paint: colors.velocity)
  panel(0, -6.5, 12, 1.3, [Entity-location lookup],
    [B → destination, row 1       C → source, row 1\ Partition mode stages the destination until explicit maintenance.])
})
