// Adapted from master-thesis/figs.typ: device-copy-reuse.
// Revisions govern data validity, independently of retained allocation capacity.
#import "_style.typ": *
#diagram({
  panel(0, 0, 3.6, 1.4, [First use], [Host revision 7\ no current record])
  panel(4.7, 0, 3.6, 1.4, [Unchanged], [Host 7 = record 7\ skip upload], paint: colors.cluster)
  panel(9.4, 0, 3.6, 1.4, [Write / invalidate], [Host revision 8\ record 7 is stale], paint: colors.output)
  arrow((3.6, -.7), (4.7, -.7))
  arrow((8.3, -.7), (9.4, -.7))
  panel(0, -2.4, 3.6, 1.4, [Upload], [Device records 7\ then run kernel])
  panel(4.7, -2.4, 3.6, 1.4, [Use current bytes], [Run kernel\ without input upload], paint: colors.cluster)
  panel(9.4, -2.4, 3.6, 1.4, [Upload again], [Device records 8\ then run kernel], paint: colors.output)
  arrow((1.8, -1.4), (1.8, -2.4))
  arrow((6.5, -1.4), (6.5, -2.4))
  arrow((11.2, -1.4), (11.2, -2.4))
  panel(0, -4.7, 13, 1.1, [Every successful call],
    [Written outputs download and become current after synchronization.])
  arrow((1.8, -3.8), (1.8, -4.7))
  arrow((6.5, -3.8), (6.5, -4.7))
  arrow((11.2, -3.8), (11.2, -4.7))
  label((6.5, -6.5), [Allocation capacity may persist through all three calls.], bold: true)
})
