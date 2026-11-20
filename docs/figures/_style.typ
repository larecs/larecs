// Shared style for the optional particle-stage figures. Build with pixi run figures.
#import "@preview/cetz:0.5.2"
#let colors = (
  stroke: rgb("#334155"), muted: rgb("#64748b"),
  position: rgb("#d4f1f7"), velocity: rgb("#dbeafe"),
  output: rgb("#ffedd5"), cluster: rgb("#dcfce7"), panel: rgb("#f1f5f9"),
)
#let diagram(body) = {
  set page(width: auto, height: auto, margin: 6pt, fill: white)
  set text(font: "Inter", size: 9pt, fill: colors.stroke)
  cetz.canvas(length: 10mm, body)
}
#let label(pos, body, anchor: "center", size: 9pt, bold: false) = {
  import cetz.draw: content
  content(pos, anchor: anchor, text(size: size, weight: if bold { "bold" } else { "regular" }, body))
}
#let panel(x, y, w, h, title, body, paint: colors.panel) = {
  import cetz.draw: rect, content
  rect((x, y), (x + w, y - h), radius: .12,
    fill: paint, stroke: (paint: colors.stroke, thickness: .6pt))
  content((x + w / 2, y - .28), text(weight: "bold", title))
  content((x + w / 2, y - (h + .38) / 2), box(width: w * 10mm - 8pt)[
    #set par(leading: 2pt, spacing: 0pt)
    #align(center, text(size: 8.5pt, body))
  ])
}
#let arrow(from, to) = {
  import cetz.draw: line
  line(from, to, stroke: (paint: colors.stroke, thickness: .7pt),
    mark: (end: ">", fill: colors.stroke, scale: .7))
}
#let strip(x, y, title, rows, paint: colors.position, paints: none) = {
  import cetz.draw: rect
  label((x, y + .25), title, anchor: "south-west", bold: true)
  for (i, value) in rows.enumerate() {
    rect((x + i * 1.1, y), (x + (i + 1) * 1.1, y - .65),
      fill: if paints == none { paint } else { paints.at(i) },
      stroke: (paint: colors.stroke, thickness: .5pt))
    label((x + (i + .5) * 1.1, y - .325), value)
  }
}
