// Adapted from master-thesis/figs.typ: host-execution,
// threaded-host-execution, device-grid-stride. Current physical-store vocabulary.
#import "_style.typ": *
#diagram({
  import cetz.draw: line
  panel(0, 0, 3.6, 1.3, [Matching rows], [Store A: 4 rows\ Store B: 3 rows])
  panel(5.0, 0, 7.2, 1.3, [Sequential HOST], [Call A: local 0–3 → call B: local 0–2])
  arrow((3.6, -.65), (5.0, -.65))
  label((0, -2.0), [Each range splits independently], anchor: "west", bold: true)
  panel(0, -2.5, 3.6, 1.4, [Threaded HOST], [Disjoint chunks\ dynamic job claims])
  panel(5.0, -2.5, 3.3, 1.4, [Worker task 1], [A chunk: local 0–1\ B chunk: local 0–1])
  panel(8.9, -2.5, 3.3, 1.4, [Worker task 2], [A chunk: local 0–1\ B chunk: local 0])
  arrow((3.6, -3.0), (5.0, -3.0))
  line((3.6, -3.7), (4.3, -3.7), (4.3, -4.2), (10.55, -4.2), (10.55, -3.9),
    stroke: (paint: colors.stroke, thickness: .7pt),
    mark: (end: ">", fill: colors.stroke, scale: .7))
  label((6.1, -4.5), [Illustrative assignment; all tasks join before return.], size: 8.5pt)
  panel(0, -5.3, 3.6, 1.4, [DEVICE], [Pack A then B\ into 7 rows])
  panel(5.0, -5.3, 7.2, 1.4, [One launch; illustrative 4 threads],
    [Thread 0: rows 0, 4    Thread 1: rows 1, 5\ Thread 2: rows 2, 6    Thread 3: row 3])
  arrow((3.6, -6.0), (5.0, -6.0))
  label((6.1, -7.3), [Each row executes once. Indices are context-local, not entity IDs.], size: 8.5pt)
})
