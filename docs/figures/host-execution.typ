// Sequential host execution of `context.run[move]()` in the first simulation.
// Adapted from the host-execution figure of the Larecs master thesis.
//
// Build: `pixi run figures` (from the repository root). The output is
// docs/site/static/images/host-execution.svg.

#import "@preview/cetz:0.5.2"

#set page(width: auto, height: auto, margin: 4pt, fill: white)

// Inter (docs/figures/fonts) is also the documentation site's font.
#let sans = "Inter"
#let mono = "DejaVu Sans Mono"

#let colors = (
  position: rgb("#8bd3e6"),
  velocity: rgb("#bfdbfe"),
  panel: rgb("#e2e8f0"),
  row: rgb("#fecaca"),
  stroke: rgb("#334155"),
  muted: rgb("#64748b"),
  read: rgb("#15803d"),
  write: rgb("#c2410c"),
)

// Component access badge: "rw" for include (read-write), "r" for read
#let access(mode) = {
  let paint = if mode == "r" { colors.read } else { colors.write }
  box(
    fill: paint.lighten(88%),
    stroke: 0.4pt + paint,
    radius: 1.5pt,
    inset: (x: 0.3em, y: 0.2em),
    baseline: 0.2em,
    text(font: mono, size: 5.5pt, weight: "bold", fill: paint, mode),
  )
}

// The world of the first simulation: two physical stores
#let stores = (
  (
    label: [Store: Position, Velocity],
    columns: ("Position", "Velocity"),
    rows: ("walker", "climber"),
    matches: true,
  ),
  (label: [Store: Position], columns: ("Position",), rows: ("marker",), matches: false),
)

#cetz.canvas(length: 8.5mm, {
  import cetz.draw: circle, content, line, rect, set-style

  let stroke = (paint: colors.stroke, thickness: 0.55pt)
  let thin = (paint: colors.muted, thickness: 0.35pt)
  let area = (paint: luma(40%), thickness: 0.7pt, dash: "dotted")
  let arrow = (end: ">", fill: colors.stroke, scale: 0.6)
  let title-style = (font: sans, weight: "bold", size: 9pt)
  let label-style = (font: sans, size: 8pt)
  let code-style = (font: mono, size: 6.5pt)
  let muted-code-style = (..code-style, fill: colors.muted)
  set-style(stroke: stroke)

  let (column-width, header-height, row-height) = (1.7, 0.5, 0.65)
  let pad = 0.2
  let store-gap = 0.5
  let store-x = 0.5
  let world-right = store-x + 2 * column-width + pad + 0.3
  let run-left = world-right + 1.4
  let context-left = run-left + 0.3
  let context-right = context-left + 4.6
  let (chip-left, chip-width, chip-height) = (context-left + 0.4, 1.3, 0.38)
  let timeline-x = context-right + 0.7
  let run-right = timeline-x + 1.0
  let top = 0
  let content-top = top - 1.6

  content((0.2, top - 0.15), anchor: "north-west", text(..title-style)[World storage])
  content((run-left + 0.2, top - 0.15), anchor: "north-west", text(..title-style)[`context.run[move]()`])
  content((run-left + 0.2, top - 0.7), anchor: "north-west", text(..code-style)[
    move_filter: Position #access("rw"), Velocity #access("r")
  ])

  let store-top = content-top
  let call-centers = ()
  let last-bottom = content-top
  for store in stores {
    let header-top = store-top - 0.6
    let rows-top = header-top - header-height
    let bottom = rows-top - store.rows.len() * row-height - pad
    let width = store.columns.len() * column-width
    let box-right = store-x + width + pad

    rect(
      (store-x - pad, bottom),
      (box-right, header-top + pad),
      fill: white,
      radius: 0.1,
      stroke: if store.matches { stroke } else { (..thin, dash: "dashed") },
    )
    content(
      (store-x - pad, store-top - 0.15),
      anchor: "west",
      text(..label-style, fill: if store.matches { black } else { colors.muted }, store.label),
    )
    for (index, name) in store.columns.enumerate() {
      let left = store-x + index * column-width
      let color = if name == "Position" { colors.position } else { colors.velocity }
      let active = store.matches
      rect((left, rows-top), (left + column-width, header-top), fill: if active { color } else { luma(94%) })
      content(
        (left + column-width / 2, rows-top + header-height / 2),
        text(..label-style, fill: if active { black } else { colors.muted }, name),
      )
      for (row, entity) in store.rows.enumerate() {
        let row-top = rows-top - row * row-height
        rect(
          (left, row-top - row-height),
          (left + column-width, row-top),
          fill: if active { color.lighten(55%) } else { luma(94%) },
          stroke: thin,
        )
        content(
          (left + column-width / 2, row-top - row-height / 2),
          text(..if active { code-style } else { muted-code-style }, entity),
        )
      }
    }

    if not store.matches {
      rect(
        (context-left, bottom),
        (context-right, store-top),
        radius: 0.12,
        stroke: (paint: colors.muted, thickness: 0.5pt, dash: "dashed"),
      )
      content(
        ((context-left + context-right) / 2, (store-top + bottom) / 2),
        align(center, text(..muted-code-style)[Velocity missing: \ no KernelContext, no call]),
      )
      store-top = bottom - store-gap
      continue
    }

    rect((context-left, bottom), (context-right, store-top), fill: white, radius: 0.12)
    content(((context-left + context-right) / 2, store-top - 0.3), text(..label-style)[KernelContext])
    content(
      (chip-left + chip-width + 0.35, rows-top - store.rows.len() * row-height / 2),
      anchor: "west",
      text(..muted-code-style)[for particle \ in context],
    )
    for (row, entity) in store.rows.enumerate() {
      let center-y = rows-top - (row + 0.5) * row-height
      rect(
        (chip-left, center-y - chip-height / 2),
        (chip-left + chip-width, center-y + chip-height / 2),
        fill: colors.row,
        radius: 0.1,
      )
      content((chip-left + chip-width / 2, center-y), text(..code-style, entity))
      line((context-left, center-y), (box-right, center-y), mark: (..arrow, scale: 0.5), stroke: thin)
      if row + 1 < store.rows.len() {
        line(
          (chip-left + chip-width / 2, center-y - chip-height / 2),
          (chip-left + chip-width / 2, center-y - row-height + chip-height / 2),
          mark: (..arrow, scale: 0.4),
        )
      }
    }
    call-centers.push((store-top + bottom) / 2)
    last-bottom = bottom
    store-top = bottom - store-gap
  }
  let stack-bottom = store-top + store-gap

  content((timeline-x, content-top), anchor: "south", text(..muted-code-style)[host thread])
  line((timeline-x, content-top - 0.1), (timeline-x, last-bottom), mark: arrow)
  for (index, center-y) in call-centers.enumerate() {
    line((context-right, center-y), (timeline-x, center-y), stroke: thin)
    circle((timeline-x, center-y), radius: 0.22, fill: white)
    content((timeline-x, center-y), text(..code-style, weight: "bold", str(index + 1)))
    content((timeline-x + 0.5, center-y), rotate(-90deg, reflow: true, text(..muted-code-style)[move(context)]))
  }

  let bottom = stack-bottom - 0.4
  rect((0, top + 0.3), (world-right, bottom), radius: 0.2, stroke: area)
  rect((run-left, top + 0.3), (run-right, bottom), radius: 0.2, stroke: area)
})
