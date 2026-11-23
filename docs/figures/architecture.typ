// Adapted from thesis.typ sec-architecture and figs.typ larecs-architecture.
// Contexts now borrow the world; physical stores and target-local bindings are explicit.
#import "_style.typ": *
#diagram({
  import cetz.draw: rect
  panel(0, 0, 4.1, 1.6, [Scheduler], [Owns World + systems\ initialize → update(s)\ → finalize])
  panel(5.2, 0, 7.2, 1.6, [System → SystemContext], [Registration-order calls\ temporary access to the owned World])
  arrow((4.1, -.8), (5.2, -.8))
  rect((0, -2.3), (12.4, -6.4), radius: .12, fill: white,
    stroke: (paint: colors.stroke, thickness: .7pt))
  label((.25, -2.65), [World owns], anchor: "west", bold: true)
  panel(.4, -3.2, 3.7, 2.3, [HostStorage], [Logical transition graph\ physical stores + columns\ IDs, locations, lock bits])
  panel(4.5, -3.2, 3.6, 2.3, [ResourceStorage], [Host source values\ source leases + revisions\ adapter allocation caches], paint: colors.cluster)
  panel(8.5, -3.2, 3.5, 2.3, [Device storage], [Optional context\ component buffers\ copy-validity records], paint: colors.velocity)
  label((6.2, -5.95), [Optional owned classifier + typed maintenance callback], size: 8.5pt)
  arrow((8.8, -1.6), (8.8, -2.3))
  panel(.4, -7.3, 11.6, 1.6, [Invocation → KernelContext],
    [Temporary column pointers + local row count + resource/capture views\ synchronous completion before binding owners are released], paint: colors.output)
  arrow((2.25, -6.4), (2.25, -7.3))
  arrow((6.3, -6.4), (6.3, -7.3))
  arrow((10.25, -6.4), (10.25, -7.3))
  label((6.2, -9.5), [Containment: ownership. Arrows: calls or borrowed access, not byte layout.], size: 8.5pt)
})
