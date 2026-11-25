# /// script
# requires-python = ">=3.11"
# dependencies = ["shapely>=2.0", "fonttools>=4.50"]
# ///
"""Generate the larecs logo exploration assets.

Every concept is built from geometric primitives in its own unit space and
then fitted into a 256 x 256 viewBox. Treatments recolor the same geometry
through four colour roles:

    a  primary form (ivory on dark, forest on light)
    b  secondary face of the primary form (fold / shading)
    c  accent (entity, node, tree)
    d  secondary accent

Usage:
    uv run branding/generate_logos.py [--font PATH] [--no-png]

The wordmark is outlined from Inter (variable, wght 500). Pass --font or set
LARECS_WORDMARK_FONT when Inter is not at the default location; without a
font, lockups fall back to editable text only.
"""

from __future__ import annotations

import argparse
import html
import json
import math
import os
import shutil
import subprocess
from dataclasses import dataclass, field
from pathlib import Path

from shapely.geometry import MultiPolygon, Polygon, box
from shapely.ops import unary_union

ROOT = Path(__file__).resolve().parent
PALETTE = json.loads((ROOT / "palette.json").read_text())
FI = PALETTE["forest-ivory"]
DE = PALETTE["dark-electric"]
EB = PALETTE["earth-blue"]

C30 = math.cos(math.radians(30))
S30 = 0.5
VIEW = 256
MARGIN = 32  # safe margin for standalone icons
AVATAR_BOX = 148  # content box inside avatar backgrounds (fits the circle crop)


def iso(u: float, v: float, w: float) -> tuple[float, float]:
    """Project isometric coordinates to screen space (y down).

    u runs up-right (depth), v runs down-right (the foot of the L),
    w runs straight up.
    """
    return ((u + v) * C30, (v - u) * S30 - w)


# --------------------------------------------------------------------------
# Geometry container
# --------------------------------------------------------------------------


@dataclass
class Shape:
    kind: str  # "poly" | "circle" | "stroke"
    role: str
    geom: object = None
    center: tuple[float, float] = (0.0, 0.0)
    r: float = 0.0
    pts: list[tuple[float, float]] = field(default_factory=list)
    width: float = 0.0
    cap: str = "butt"


class Mark:
    """A list of role-coloured shapes in unit space."""

    def __init__(self) -> None:
        self.shapes: list[Shape] = []

    def poly(self, pts, role="a", gap=0.0):
        g = Polygon(pts) if not hasattr(pts, "geom_type") else pts
        if gap:
            g = g.buffer(-gap / 2, join_style="mitre", mitre_limit=8)
        self.shapes.append(Shape("poly", role, geom=g))
        return g

    def circle(self, c, r, role="c"):
        self.shapes.append(Shape("circle", role, center=c, r=r))

    def knockout(self, geom, gap):
        """Cut `geom` grown by `gap` out of every polygon added so far."""
        cut = geom.buffer(gap, join_style="mitre", mitre_limit=8)
        for sh in self.shapes:
            if sh.kind == "poly":
                sh.geom = sh.geom.difference(cut)

    def stroke(self, pts, width, role="a", cap="butt"):
        self.shapes.append(Shape("stroke", role, pts=list(pts), width=width, cap=cap))

    def bounds(self):
        xs0, ys0, xs1, ys1 = [], [], [], []
        for s in self.shapes:
            if s.kind == "poly":
                b = s.geom.bounds
            elif s.kind == "circle":
                b = (s.center[0] - s.r, s.center[1] - s.r, s.center[0] + s.r, s.center[1] + s.r)
            else:
                h = s.width / 2
                xs = [p[0] for p in s.pts]
                ys = [p[1] for p in s.pts]
                b = (min(xs) - h, min(ys) - h, max(xs) + h, max(ys) + h)
            xs0.append(b[0]); ys0.append(b[1]); xs1.append(b[2]); ys1.append(b[3])
        return min(xs0), min(ys0), max(xs1), max(ys1)


def _fmt(x: float) -> str:
    s = f"{x:.2f}".rstrip("0").rstrip(".")
    return "0" if s == "-0" else s


def _ring(coords, tf) -> str:
    pts = [tf(p) for p in list(coords)[:-1]]
    return "M" + " L".join(f"{_fmt(x)} {_fmt(y)}" for x, y in pts) + " Z"


def render_mark(mark: Mark, colors: dict[str, str], box_size: float, offset=(0.0, 0.0),
                origin=(VIEW / 2, VIEW / 2), scale: float | None = None) -> str:
    """Return SVG elements for `mark`, fitted into a centred square box."""
    x0, y0, x1, y1 = mark.bounds()
    w, h = x1 - x0, y1 - y0
    # Optical sizing: narrow marks may grow up to 8 % past the box so their
    # visual weight matches compact marks.
    k = min(1.08 * box_size / max(w, h), box_size / math.sqrt(w * h))
    if scale is not None:
        k = scale
    cx, cy = (x0 + x1) / 2, (y0 + y1) / 2
    ox = origin[0] + offset[0] * box_size / 192
    oy = origin[1] + offset[1] * box_size / 192

    def tf(p):
        return (ox + (p[0] - cx) * k, oy + (p[1] - cy) * k)

    out = []
    for s in mark.shapes:
        col = colors[s.role]
        if s.kind == "poly":
            geoms = s.geom.geoms if isinstance(s.geom, MultiPolygon) else [s.geom]
            d = " ".join(
                " ".join([_ring(g.exterior.coords, tf)] + [_ring(i.coords, tf) for i in g.interiors])
                for g in geoms if not g.is_empty
            )
            out.append(f'<path class="r-{s.role}" fill="{col}" fill-rule="evenodd" d="{d}"/>')
        elif s.kind == "circle":
            x, y = tf(s.center)
            out.append(f'<circle class="r-{s.role}" fill="{col}" cx="{_fmt(x)}" cy="{_fmt(y)}" r="{_fmt(s.r * k)}"/>')
        else:
            pts = " ".join(f"{_fmt(x)},{_fmt(y)}" for x, y in map(tf, s.pts))
            out.append(
                f'<polyline class="r-{s.role}" fill="none" stroke="{col}" stroke-width="{_fmt(s.width * k)}" '
                f'stroke-linecap="{s.cap}" stroke-linejoin="miter" points="{pts}"/>'
            )
    return "\n  ".join(out)


# --------------------------------------------------------------------------
# Concepts
# --------------------------------------------------------------------------

CONCEPTS: list[dict] = []


def concept(cid, family, name, desc, offset=(0, 0)):
    def deco(fn):
        CONCEPTS.append(dict(id=cid, family=family, name=name, desc=desc, build=fn, offset=offset))
        return fn
    return deco


def corner_planes(m: Mark, D=1.25, H=2.7, Lf=1.7, gap=0.12):
    """The 6.1 construction: an isometric wall folded into a floor plane."""
    m.poly([iso(0, 0, 0), iso(D, 0, 0), iso(D, 0, H), iso(0, 0, H)], "a", gap)
    m.poly([iso(0, 0, 0), iso(0, Lf, 0), iso(D, Lf, 0), iso(D, 0, 0)], "b", gap)


@concept("L01", "l-monogram", "Corner",
         "Reconstruction of the preferred 6.1: an isometric wall folds into a floor plane, "
         "the L read as the corner of a space. A single entity stands on its own cell.")
def _l01():
    m = Mark()
    corner_planes(m)
    t0, t1, v0, v1 = 1.47, 2.27, 0.35, 1.25
    m.poly([iso(t0, v0, 0), iso(t0, v1, 0), iso(t1, v1, 0), iso(t1, v0, 0)], "d")
    cu, cv = (t0 + t1) / 2, (v0 + v1) / 2
    m.stroke([iso(cu, cv, 0.0), iso(cu, cv, 1.05)], 0.17, "c")
    m.circle(iso(cu, cv, 1.25), 0.36, "c")
    return m


@concept("L02", "l-monogram", "Slit hexagon",
         "A solid isometric emblem. The L is never drawn: it is the slit that separates "
         "the occupied corner from one free cell of space.")
def _l02():
    m = Mark()
    R = 1.0
    o = (0.0, 0.0)
    W, U, V = iso(0, 0, R), iso(R, 0, 0), iso(0, R, 0)
    add = lambda *ps: (sum(p[0] for p in ps), sum(p[1] for p in ps))
    neg = lambda p: (-p[0], -p[1])
    rest = Polygon([o, W, add(W, neg(U)), neg(U), add(V, neg(U)), V])
    cell = Polygon([o, V, add(V, W), W])
    g = 0.13
    rest_s = rest.buffer(-g / 2, join_style="mitre", mitre_limit=8)
    m.poly(rest_s, "a")
    floor = Polygon([o, neg(U), add(V, neg(U)), V]).intersection(rest_s)
    m.poly(floor, "b")
    m.poly(cell, "c", g)
    return m


@concept("L03", "l-monogram", "Cells",
         "Five spatial cells set out as an L on an implied 3 x 3 grid; a single entity "
         "occupies the cell the L encloses.")
def _l03():
    m = Mark()
    for c, r in [(0, 0), (0, 1), (0, 2), (1, 2), (2, 2)]:
        m.poly(box(c, r, c + 1, r + 1), "a", 0.2)
    m.circle((1.5, 1.5), 0.36, "c")
    return m


@concept("L04", "l-monogram", "Extruded",
         "A shallow isometric extrusion of the L. Front, top and side faces carry the "
         "three palette tones; the L reads in the front face alone.")
def _l04():
    m = Mark()
    a, H, Lf, d = 0.62, 2.6, 1.9, 0.85
    p = lambda v, w, u: iso(u, v, w)
    g = 0.08
    m.poly([p(0, H, 0), p(a, H, 0), p(a, H, d), p(0, H, d)], "b", g)
    m.poly([p(a, a, 0), p(Lf, a, 0), p(Lf, a, d), p(a, a, d)], "b", g)
    m.poly([p(a, a, 0), p(a, H, 0), p(a, H, d), p(a, a, d)], "c", g)
    m.poly([p(Lf, 0, 0), p(Lf, a, 0), p(Lf, a, d), p(Lf, 0, d)], "c", g)
    m.poly([p(0, 0, 0), p(Lf, 0, 0), p(Lf, a, 0), p(a, a, 0), p(a, H, 0), p(0, H, 0)], "a", g)
    return m


@concept("L05", "l-monogram", "Axes",
         "The three isometric axes drawn from one origin. Up and forward form the L; "
         "the depth axis branches into the space and ends in an entity node.")
def _l05():
    m = Mark()
    sw = 0.42
    m.stroke([iso(0, 0, 2.5), iso(0, 0, 0), iso(0, 1.6, 0)], sw, "a")
    m.stroke([iso(0.5, 0, 0), iso(1.0, 0, 0)], sw, "d")
    m.circle(iso(1.32, 0, 0), 0.4, "c")
    return m


@concept("L06", "l-monogram", "Segmented corner",
         "The 6.1 corner rebuilt from five identical isometric cells: three stacked in the "
         "wall, two laid in the floor, the outermost one an active entity.")
def _l06():
    m = Mark()
    g = 0.16
    D = 1.3
    for k in range(3):
        m.poly([iso(0, 0, k), iso(D, 0, k), iso(D, 0, k + 1), iso(0, 0, k + 1)], "a", g)
    for j, role in [(0, "b"), (1, "c")]:
        m.poly([iso(0, j, 0), iso(0, j + 1, 0), iso(D, j + 1, 0), iso(D, j, 0)], role, g)
    return m


@concept("L07", "l-monogram", "Cut L + spire",
         "A flat L with 30 / 60 degree cuts and a chamfered heel. An equilateral spire "
         "sits in the crook: the forest reduced to a single angle.")
def _l07():
    m = Mark()
    t, H, Lf, ch = 0.6, 2.6, 1.95, 0.22
    tn = math.tan(math.radians(30))
    m.poly([(0, t * tn), (t, 0), (t, H - t), (Lf, H - t), (Lf - t * tn, H), (ch, H), (0, H - ch)], "a")
    gap = 0.17
    x0, x1 = t + gap, Lf - t * tn * 0.2
    base_y = H - t - gap
    hgt = (x1 - x0) * C30
    m.poly([(x0, base_y), (x1, base_y), ((x0 + x1) / 2, base_y - hgt)], "c")
    return m


@concept("L08", "l-monogram", "Quadtree",
         "Recursive spatial subdivision: each square keeps three quadrants as an L and "
         "subdivides the fourth, ending in a single entity.")
def _l08():
    m = Mark()
    x0, y0, s = 0.0, 0.0, 2.0
    for role in ["a", "d"]:
        h = s / 2
        m.poly([(x0, y0), (x0 + h, y0), (x0 + h, y0 + h), (x0 + s, y0 + h), (x0 + s, y0 + s), (x0, y0 + s)],
               role, 0.075 * s)
        x0, y0, s = x0 + h, y0, h
    m.circle((x0 + s / 2, y0 + s / 2), s * 0.36, "c")
    return m


@concept("L09", "l-monogram", "Corner + node",
         "6.1 reduced to its essentials: wall, floor and one entity floating in the "
         "space they define. No stem, no tile.")
def _l09():
    m = Mark()
    corner_planes(m)
    m.circle(iso(0.7, 1.05, 1.15), 0.42, "c")
    return m


@concept("L10", "l-monogram", "Folded ribbon",
         "One continuous strip folded twice along isometric edges: up the wall, across "
         "the floor and up into a short step, an L that implies terrain.")
def _l10():
    m = Mark()
    D, H, Lf, h2, g = 1.25, 2.7, 1.55, 0.95, 0.12
    m.poly([iso(0, 0, 0), iso(D, 0, 0), iso(D, 0, H), iso(0, 0, H)], "a", g)
    m.poly([iso(0, 0, 0), iso(0, Lf, 0), iso(D, Lf, 0), iso(D, 0, 0)], "b", g)
    m.poly([iso(0, Lf, 0), iso(D, Lf, 0), iso(D, Lf, h2), iso(0, Lf, h2)], "c", g)
    return m



# --------------------------------------------------------------------------
# Tree-led L concepts (round 2)
# --------------------------------------------------------------------------

T30 = math.tan(math.radians(30))


def conifer(bx, by, h, w, tiers=2, trunk=0.14, taper=0.24):
    """Tiered conifer silhouette standing on (bx, by), y down."""
    th = h * trunk
    parts = [box(bx - w * 0.07, by - th - 0.01, bx + w * 0.07, by)] if trunk else []
    hh = (h - th) * (0.62 if tiers > 1 else 1.0)
    step = (h - th - hh) / (tiers - 1) if tiers > 1 else 0
    for k in range(tiers):
        yb = by - th - k * step
        hw = w / 2 * (1 - taper * k)
        parts.append(Polygon([(bx - hw, yb), (bx + hw, yb), (bx, yb - hh)]))
    return unary_union(parts)


@concept("T01", "l-tree", "Corner + conifer",
         "The 6.1 corner with a single conifer standing on the floor, knocked out of the "
         "planes so it survives in one colour.")
def _t01():
    m = Mark()
    D, H, Lf = 1.5, 3.15, 2.05
    corner_planes(m, D=D, H=H, Lf=Lf, gap=0.12)
    tree = conifer(*iso(D * 0.5, Lf * 0.68, 0), h=2.4, w=1.1, tiers=1, trunk=0.22)
    m.knockout(tree, 0.11)
    m.poly(tree, "c")
    return m


@concept("T02", "l-tree", "Spruce stem",
         "The L is the tree: one stem runs from the tip down to the ground line, and the "
         "conifer tiers open out on both sides of it.")
def _t02():
    m = Mark()
    t, H, Lf = 0.42, 3.0, 1.8
    crown = conifer(t / 2, 1.95, 1.95, 1.75, tiers=2, trunk=0)
    stem = Polygon([(0, 0.36), (t / 2, 0.0), (t, 0.36),
                    (t, H - t), (Lf, H - t), (Lf - t * T30, H), (0, H)])
    m.poly(crown.difference(box(-0.12, -1, t + 0.12, H + 1)), "c")
    m.poly(stem, "a")
    return m


def fillet_ring(pts, radii, steps=16):
    """Replace ring vertices with circular arcs of the given radii (0 = sharp).

    Works for convex and concave corners. A radius is clamped so its tangent
    points stay on the adjacent edges.
    """
    out = []
    n = len(pts)
    for k, v in enumerate(pts):
        r = radii[k]
        if not r:
            out.append(v)
            continue
        a, b = pts[k - 1], pts[(k + 1) % n]
        la, lb = math.dist(a, v), math.dist(v, b)
        if la < 1e-9 or lb < 1e-9:
            out.append(v)
            continue
        u1 = ((v[0] - a[0]) / la, (v[1] - a[1]) / la)
        u2 = ((b[0] - v[0]) / lb, (b[1] - v[1]) / lb)
        th = math.acos(max(-1.0, min(1.0, u1[0] * u2[0] + u1[1] * u2[1])))
        if th < 1e-6:
            out.append(v)
            continue
        r = min(r, 0.95 * min(la, lb) / math.tan(th / 2))
        d = r * math.tan(th / 2)
        t1 = (v[0] - u1[0] * d, v[1] - u1[1] * d)
        t2 = (v[0] + u2[0] * d, v[1] + u2[1] * d)
        bx, by = u2[0] - u1[0], u2[1] - u1[1]
        bl = math.hypot(bx, by)
        c = (v[0] + bx / bl * r / math.cos(th / 2), v[1] + by / bl * r / math.cos(th / 2))
        a1 = math.atan2(t1[1] - c[1], t1[0] - c[0])
        a2 = math.atan2(t2[1] - c[1], t2[0] - c[0])
        da = (a2 - a1 + math.pi) % (2 * math.pi) - math.pi
        out += [(c[0] + r * math.cos(a1 + da * i / steps), c[1] + r * math.sin(a1 + da * i / steps))
                for i in range(steps + 1)]
    return out


def half_spruce(rounded: bool):
    m = Mark()
    # Chosen T03R proportions (see README); T03 shares them with a sharp bend.
    H, tw, t, ft, f, g, n = 3.0, 0.36, 0.38, 0.62, 1.0, 0.18, 3  # t: branch, ft: foot thickness
    longest, shortest = 0.87, 0.55  # x extent of the lowest and highest upper branch
    r_out, r_in = 0.2, 0.2
    branch = lambda x0, x1, y: Polygon([(x0, y + x0 * T30), (x1, y + x1 * T30),
                                        (x1, y + x1 * T30 + t), (x0, y + x0 * T30 + t)])
    yf = H - ft
    # Stem and foot as one ring: the stem stops at the foot's upper edge so the
    # foot's underside continues to the stem's outer edge (one bend, no step).
    ring = [(-tw, 0), (-tw, yf - tw * T30 + ft), (f, yf + f * T30 + ft), (f, yf + f * T30), (0, yf), (0, 0)]
    if rounded:
        ring = fillet_ring(ring, [0, r_out, 0, 0, r_in, 0])
    m.poly(ring, "a")
    for i in range(1, n + 1):
        fr = i / (n + 1)
        x1 = longest + (shortest - longest) * ((i - 1) / (n - 1) if n > 1 else 0)
        m.poly(branch(g, x1, yf * (1 - fr) - t * 0.2), "c")
    return m


@concept("T03", "l-tree", "Half spruce",
         "Stem and branches on isometric angles form one side of a spruce. Stem and foot "
         "meet in one mitred bend: the L.")
def _t03():
    return half_spruce(rounded=False)


@concept("T03R", "l-tree", "Half spruce, rounded",
         "T03 with the bend between stem and foot rounded on both the outer and inner edge.")
def _t03r():
    return half_spruce(rounded=True)


# The chosen logo. Mirrors spruceL() and the V12 preset in previews/playground.html.
V12 = dict(tw=0.29, taper=1, ft=0.37, f=1.1, t=0.28, gap=0.17, n=4, bmax=1, bmin=0.44, dy=-0.08, ang=36,
           ro=0.2, ri=0.2, rto=0.17, rti=0.07, rft=0.04, rfb=0.25, rb=0, rbi=0, ts=0.03, fs=-0.34, bs=0.06)
# Slider ranges of the playground's spruceL() parameters (min, max); used to
# clamp presets that arrive from outside, e.g. share links in PR comments.
SPRUCE_RANGES = dict(tw=(0.15, 0.9), taper=(0.1, 1), ft=(0.1, 0.9), f=(0.6, 3), t=(0.1, 0.7), gap=(0, 0.4),
                     n=(1, 5), bmax=(0.2, 2.5), bmin=(0.2, 2.5), dy=(-0.8, 0.8), ang=(10, 45), ro=(0, 2),
                     ri=(0, 1.5), rto=(0, 0.5), rti=(0, 0.5), rft=(0, 0.5), rfb=(0, 0.5), rb=(0, 0.4),
                     rbi=(0, 0.4), ts=(-0.6, 0.6), fs=(-0.6, 0.6), bs=(-0.6, 0.6))


def spruce_l(p):
    """Generalised half spruce: per-corner radii, sheared cuts, any slant angle."""
    m = Mark()
    H, S = 3.0, math.tan(math.radians(p["ang"]))
    tw, t, ft, f = p["tw"], p["t"], p["ft"], p["f"]
    yf = H - ft
    ring = [(-tw * p["taper"], p["ts"]), (-tw, yf - tw * S + ft), (f + p["fs"], yf + (f + p["fs"]) * S + ft),
            (f, yf + f * S), (0, yf), (0, 0)]
    m.poly(fillet_ring(ring, [p["rto"], p["ro"], p["rfb"], p["rft"], p["ri"], p["rti"]]), "a")
    n = p["n"]
    for i in range(1, n + 1):
        fr = i / (n + 1)
        x1 = p["bmax"] + (p["bmin"] - p["bmax"]) * ((i - 1) / (n - 1) if n > 1 else 0)
        y, g = yf * (1 - fr) - t * 0.2 + p["dy"], p["gap"]
        if x1 <= g:
            continue
        br = [(g, y + g * S), (x1, y + x1 * S), (x1 + p["bs"], y + (x1 + p["bs"]) * S + t), (g, y + g * S + t)]
        m.poly(fillet_ring(br, [p["rbi"], p["rb"], p["rb"], p["rbi"]]), "c")
    return m


@concept("V12", "logo", "Square L, rounded L",
         "The logo: a 36° half spruce with four branches, a square-cut foot and "
         "individually rounded stem and foot corners.")
def _v12():
    return spruce_l(V12)


@concept("T04", "l-tree", "Canopy L",
         "A flat L whose stem ends in a round crown: a single tree whose root runs out "
         "along the ground.")
def _t04():
    m = Mark()
    t, H, Lf, r = 0.5, 3.0, 1.75, 0.62
    m.poly([(0, 0.9), (t, 0.9), (t, H - t), (Lf, H - t), (Lf - t * T30, H), (0, H)], "a")
    from shapely.geometry import Point
    crown = Point(t / 2, 0.75).buffer(r, 64)
    m.knockout(crown, 0.12)
    m.circle((t / 2, 0.75), r, "c")
    return m


@concept("T05", "l-tree", "Quadtree forest",
         "The quadtree L (L08) whose final leaf is a conifer: a forest stored in a spatial "
         "index.")
def _t05():
    m = Mark()
    x0, y0, s = 0.0, 0.0, 2.0
    for role in ["a", "d"]:
        h = s / 2
        m.poly([(x0, y0), (x0 + h, y0), (x0 + h, y0 + h), (x0 + s, y0 + h), (x0 + s, y0 + s), (x0, y0 + s)],
               role, 0.075 * s)
        x0, y0, s = x0 + h, y0, h
    m.poly(conifer(x0 + s / 2, y0 + s * 0.92, s * 0.86, s * 0.72, tiers=2, trunk=0), "c")
    return m


@concept("T06", "l-tree", "Seam spruce",
         "Two triangles on a stem. A white spruce triangle loses its upper right corner "
         "along an L-shaped seam; a green triangle fills the gap down to the seam.")
def _t06():
    m = Mark()
    # Proportions: height, white and green taper (base half-width / height),
    # seam width, seam height above the base, stem height (fraction of H) and
    # stem width (fraction of the white base width).
    H, tw, tg, sw, sy, trunk, stem_w = 3.0, 0.45, 0.61, 0.34, 1.2, 0.18, 0.14
    s, th = sw / 2, H * trunk
    yb = -th - sy  # seam centre line
    hw = (H - th) * tw
    white = Polygon([(0, -H), (hw, -th), (-hw, -th)]).difference(box(-s, -H - 1, hw + 1, yb + s))
    if th:
        white = unary_union([white, box(-hw * stem_w, -th - 0.01, hw * stem_w, 0)])
    gy0, gy1 = -H, yb - s
    green = Polygon([(s, gy0), (s, gy1), (s + (gy1 - gy0) * tg, gy1)])
    m.poly(white, "a")
    m.poly(green, "c")
    return m


@concept("T07", "l-tree", "Grove corner",
         "The 6.1 corner holding a small grove: two conifers of different heights on the "
         "floor plane.")
def _t07():
    m = Mark()
    corner_planes(m, Lf=2.0)
    t1 = conifer(*iso(1.0, 0.55, 0), h=1.8, w=0.9)
    t2 = conifer(*iso(0.3, 1.7, 0), h=1.15, w=0.7)
    m.knockout(unary_union([t1, t2]), 0.09)
    m.poly(t1, "c")
    m.knockout(t2, 0.09)
    m.poly(t2, "c")
    return m


@concept("B01", "minimal-branch", "Iso branch",
         "Secondary 5.1: a trunk with two asymmetric branches on isometric angles and "
         "three entity nodes.")
def _b01():
    m = Mark()
    sw = 0.24
    m.stroke([iso(0, 0, 0), iso(0, 0, 2.3)], sw, "a")
    m.stroke([iso(0, 0, 0.85), iso(0, -1.0, 0.85)], sw, "a")
    m.stroke([iso(0, 0, 1.5), iso(0.85, 0, 1.5)], sw, "a")
    m.circle(iso(0, 0, 2.55), 0.32, "c")
    m.circle(iso(0, -1.25, 0.85), 0.28, "c")
    m.circle(iso(1.08, 0, 1.5), 0.25, "d")
    return m


@concept("G01", "grid-forest", "Sparse grid",
         "Secondary 4.4: a 2 x 2 isometric grid of cells holding two tree entities on a "
         "diagonal.")
def _g01():
    m = Mark()
    for i in range(2):
        for j in range(2):
            m.poly([iso(i, j, 0), iso(i, j + 1, 0), iso(i + 1, j + 1, 0), iso(i + 1, j, 0)],
                   "d" if (i, j) in [(0, 0), (1, 1)] else "b", 0.14)
    for (i, j, h) in [(1, 1, 1.35), (0, 0, 0.95)]:
        m.stroke([iso(i + .5, j + .5, 0), iso(i + .5, j + .5, h)], 0.14, "a")
        m.circle(iso(i + .5, j + .5, h + 0.2), 0.3, "c")
    return m


# --------------------------------------------------------------------------
# Treatments
# --------------------------------------------------------------------------


def mono(c):
    return dict(a=c, b=c, c=c, d=c)


SCHEMES = {
    "color-dark": dict(group="dark", label="Full colour (dark)", bg=FI["deep-forest"],
                       colors=dict(a=FI["ivory"], b=FI["ivory-shade"], c=FI["light-green"], d=FI["green"])),
    "color-light": dict(group="light", label="Full colour (light)", bg=FI["ivory"],
                        colors=dict(a=FI["forest"], b=FI["forest-shade"], c=FI["green"], d=FI["light-green"])),
    "ivory": dict(group="dark", label="Ivory on deep forest", bg=FI["deep-forest"], colors=mono(FI["ivory"])),
    "forest": dict(group="light", label="Deep forest on ivory", bg=FI["ivory"], colors=mono(FI["deep-forest"])),
    "black": dict(group="monochrome", label="Pure black", bg="#FFFFFF", colors=mono("#000000")),
    "white": dict(group="monochrome", label="Pure white", bg="#000000", colors=mono("#FFFFFF")),
    "muted": dict(group="monochrome", label="Muted green", bg=FI["ivory"], colors=mono(FI["green"])),
    "electric": dict(group="dark", label="Alt: dark + electric", bg=DE["near-black"],
                     colors=dict(a=DE["off-white"], b="#C3CBC1", c=DE["bright-green"], d=DE["green"])),
    "earth": dict(group="dark", label="Alt: earth + blue", bg=EB["charcoal"],
                  colors=dict(a=EB["off-white"], b="#C4C0B2", c=EB["blue"], d=EB["earth"])),
}


def svg_doc(body: str, w=VIEW, h=VIEW, title="larecs") -> str:
    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {_fmt(w)} {_fmt(h)}" '
            f'width="{_fmt(w)}" height="{_fmt(h)}">\n  <title>{html.escape(title)}</title>\n  {body}\n</svg>\n')


def icon_body(c, scheme, box_size=VIEW - 2 * MARGIN, origin=(VIEW / 2, VIEW / 2)):
    return render_mark(c["mark"], SCHEMES[scheme]["colors"], box_size, c["offset"], origin)


# --------------------------------------------------------------------------
# Wordmark
# --------------------------------------------------------------------------


class Wordmark:
    TEXT = "larecs"

    def __init__(self, font_path: Path | None):
        self.paths = None
        if font_path and font_path.exists():
            from fontTools.pens.boundsPen import BoundsPen
            from fontTools.pens.svgPathPen import SVGPathPen
            from fontTools.pens.transformPen import TransformPen
            from fontTools.ttLib import TTFont
            from fontTools.varLib.instancer import instantiateVariableFont

            font = TTFont(font_path)
            if "fvar" in font:
                axes = {a.axisTag for a in font["fvar"].axes}
                loc = {"wght": 500}
                if "opsz" in axes:
                    loc["opsz"] = 32
                font = instantiateVariableFont(font, loc)
            gs = font.getGlyphSet()
            cmap = font.getBestCmap()
            upm = font["head"].unitsPerEm
            tracking = -0.005 * upm
            x = 0.0
            parts = []
            top = 0.0
            for ch in self.TEXT:
                gname = cmap[ord(ch)]
                pen = SVGPathPen(gs)
                gs[gname].draw(TransformPen(pen, (1, 0, 0, -1, x, 0)))
                parts.append(pen.getCommands())
                bp = BoundsPen(gs)
                gs[gname].draw(bp)
                if bp.bounds:
                    top = max(top, bp.bounds[3])
                x += gs[gname].width + tracking
            self.paths = " ".join(parts)
            self.advance = x - tracking
            self.top = top  # ascender of "l" in font units
            self.upm = upm

    def element(self, x, baseline, height, color) -> str:
        """Outlined wordmark whose ascender height equals `height`."""
        if self.paths is None:
            fs = height / 0.76
            return (f'<text x="{_fmt(x)}" y="{_fmt(baseline)}" font-family="Inter, Manrope, sans-serif" '
                    f'font-weight="500" font-size="{_fmt(fs)}" fill="{color}">{self.TEXT}</text>')
        k = height / self.top
        return (f'<path fill="{color}" transform="translate({_fmt(x)} {_fmt(baseline)}) scale({k:.5f})" '
                f'd="{self.paths}"/>')

    def width(self, height):
        if self.paths is None:
            return height / 0.76 * 0.6 * len(self.TEXT)
        return self.advance * height / self.top


def lockup_svg(c, scheme, wm: Wordmark, editable=False, bg=False):
    ih = 120
    th = ih * 0.5
    gapx = ih * 0.2
    tw = wm.width(th)
    W = ih + gapx + tw + 8
    col = SCHEMES[scheme]["colors"]["a"]
    icon = render_mark(c["mark"], SCHEMES[scheme]["colors"], ih * 0.84, c["offset"], origin=(ih / 2, ih / 2))
    baseline = ih / 2 + th / 2
    if editable:
        text = (f'<text x="{_fmt(ih + gapx)}" y="{_fmt(baseline)}" font-family="Inter, Manrope, sans-serif" '
                f'font-weight="500" font-size="{_fmt(th / 0.757)}" fill="{col}">larecs</text>')
    else:
        text = wm.element(ih + gapx, baseline, th, col)
    back = f'<rect width="{_fmt(W)}" height="{ih}" fill="{SCHEMES[scheme]["bg"]}"/>\n  ' if bg else ""
    return svg_doc(back + icon + "\n  " + text, W, ih, f"larecs {c['id']} lockup")


# --------------------------------------------------------------------------
# Boards
# --------------------------------------------------------------------------


def nest(inner_svg: str, x, y, size_w, size_h=None) -> str:
    """Embed an svg document at (x, y) with the given size."""
    size_h = size_h or size_w
    body = inner_svg.split(">", 1)[1].rsplit("</svg>", 1)[0]
    vb = inner_svg.split('viewBox="', 1)[1].split('"', 1)[0]
    return (f'<svg x="{_fmt(x)}" y="{_fmt(y)}" width="{_fmt(size_w)}" height="{_fmt(size_h)}" '
            f'viewBox="{vb}">{body}</svg>')


def label(x, y, text, color, size=14, weight=500, anchor="start"):
    return (f'<text x="{_fmt(x)}" y="{_fmt(y)}" font-family="Inter, Helvetica, sans-serif" font-size="{size}" '
            f'font-weight="{weight}" fill="{color}" text-anchor="{anchor}">{html.escape(text)}</text>')


def icon_svg(c, scheme, bg=None, shape=None, box_size=VIEW - 2 * MARGIN):
    back = ""
    if bg and shape == "circle":
        back = f'<circle cx="128" cy="128" r="128" fill="{bg}"/>\n  '
    elif bg and shape == "rounded":
        back = f'<rect width="256" height="256" rx="56" fill="{bg}"/>\n  '
    elif bg:
        back = f'<rect width="256" height="256" fill="{bg}"/>\n  '
    return svg_doc(back + icon_body(c, scheme, box_size), title=f"larecs {c['id']} {c['name']}")


def comparison_board(concepts, title):
    cell, pad = 300, 24
    cols = ["color-dark", "color-light", "ivory", "black", "avatar"]
    W = pad + len(cols) * (cell / 2 + pad) + 260
    rows = len(concepts)
    rh = cell / 2 + pad
    H = 80 + rows * rh + pad
    ink = FI["ivory"]
    out = [f'<rect width="{_fmt(W)}" height="{_fmt(H)}" fill="#08110D"/>', label(pad, 46, title, ink, 26, 600)]
    for i, c in enumerate(concepts):
        y = 80 + i * rh
        out.append(label(pad, y + 30, c["id"], FI["light-green"], 20, 600))
        out.append(label(pad, y + 54, c["name"], ink, 15))
        for j, sch in enumerate(cols):
            x = 260 + j * (cell / 2 + pad)
            s = cell / 2
            if sch == "avatar":
                inner = icon_svg(c, "color-dark", FI["forest"], "circle", AVATAR_BOX)
            else:
                inner = icon_svg(c, sch, SCHEMES[sch]["bg"])
            out.append(nest(inner, x, y, s))
    return svg_doc("\n  ".join(out), W, H, title)


def size_board(concepts):
    sizes = [16, 24, 32, 48, 64, 128]
    pad = 20
    W = 120 + sum(s + pad for s in sizes) * 2 + 40
    rows = []
    y = 70
    ink = FI["ivory"]
    out = [label(pad, 40, "Size test: dark / light", ink, 22, 600)]
    for c in concepts:
        rows.append(label(pad, y + 40, c["id"], FI["light-green"], 18, 600))
        x = 120
        for sch in ["color-dark", "color-light"]:
            bgc = SCHEMES[sch]["bg"]
            band_w = sum(s + pad for s in sizes) + pad
            rows.append(f'<rect x="{x - pad / 2}" y="{y - 6}" width="{band_w}" height="140" fill="{bgc}"/>')
            for s in sizes:
                rows.append(nest(icon_svg(c, sch), x, y + (128 - s) / 2, s))
                x += s + pad
            x += pad + 10
        y += 152
    H = y + 20
    return svg_doc(f'<rect width="{_fmt(W)}" height="{_fmt(H)}" fill="#08110D"/>\n  ' +
                   "\n  ".join(out + rows), W, H, "size test")


# --------------------------------------------------------------------------
# HTML gallery
# --------------------------------------------------------------------------


def gallery_html(concepts) -> str:
    sizes = [16, 24, 32, 48, 64, 128, 256]
    swatches = "".join(
        f'<div class="sw"><span style="background:{v}"></span><code>{k}<br>{v}</code></div>'
        for k, v in FI.items()
    )
    cards = []
    for c in concepts:
        fam = c["family"]
        base = f"../concepts/{fam}/{c['id']}"
        var = lambda sch: f"../variants/{SCHEMES[sch]['group']}/{c['id']}-{sch}.svg"
        treat = "".join(
            f'<figure><div class="tile" style="background:{SCHEMES[s]["bg"]}"><img src="{var(s)}" alt=""></div>'
            f'<figcaption>{SCHEMES[s]["label"]}</figcaption></figure>'
            for s in SCHEMES
        )
        treat += (f'<figure><div class="tile checker"><img src="{base}.svg" alt=""></div>'
                  f'<figcaption>Transparent</figcaption></figure>')
        size_rows = "".join(
            f'<div class="sizes" style="background:{SCHEMES[s]["bg"]}">'
            + "".join(f'<img src="{var(s)}" width="{z}" height="{z}" title="{z}px" alt="">' for z in sizes)
            + "</div>"
            for s in ["color-dark", "color-light", "black"]
        )
        avatars = (
            f'<img class="av round" src="../avatars/{c["id"]}-forest.svg" alt="">'
            f'<img class="av round" src="../avatars/{c["id"]}-deep.svg" alt="">'
            f'<img class="av round" src="../avatars/{c["id"]}-ivory.svg" alt="">'
            f'<img class="av" src="../avatars/{c["id"]}-forest.svg" alt="">'
            f'<img class="av" src="../avatars/{c["id"]}-ivory.svg" alt="">'
            + "".join(f'<img class="av round" style="width:{z}px;height:{z}px" src="../avatars/{c["id"]}-forest.svg" alt="">'
                      for z in [20, 32, 48])
        )
        lockups = (
            f'<div class="lock" style="background:{FI["deep-forest"]}"><img src="../wordmarks/{c["id"]}-dark.svg" alt=""></div>'
            f'<div class="lock" style="background:{FI["ivory"]}"><img src="../wordmarks/{c["id"]}-light.svg" alt=""></div>'
        )
        cards.append(f"""
<section class="card" id="{c['id']}">
  <header><h2><span>{c['id']}</span> {html.escape(c['name'])}</h2><p>{html.escape(c['desc'])}</p></header>
  <div class="hero">
    <div style="background:{FI['deep-forest']}"><img src="{var('color-dark')}" alt=""></div>
    <div style="background:{FI['ivory']}"><img src="{var('color-light')}" alt=""></div>
  </div>
  <h3>Sizes (16 / 24 / 32 / 48 / 64 / 128 / 256)</h3>{size_rows}
  <h3>Avatars</h3><div class="avatars">{avatars}</div>
  <h3>Lockups</h3><div class="locks">{lockups}</div>
  <h3>Treatments</h3><div class="treat">{treat}</div>
</section>""")
    nav = " ".join(f'<a href="#{c["id"]}">{c["id"]}</a>' for c in concepts)
    overview = "".join(
        f'<a class="ov" href="#{c["id"]}"><img src="../variants/dark/{c["id"]}-color-dark.svg" alt="">'
        f'<span>{c["id"]} · {html.escape(c["name"])}</span></a>'
        for c in concepts
    )
    return f"""<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>larecs logo exploration</title>
<style>
:root {{ --bg:#08110D; --ink:{FI['ivory']}; --mut:#9DA89F; --acc:{FI['light-green']}; --line:#1d2a23; }}
* {{ box-sizing:border-box }}
body {{ margin:0; background:var(--bg); color:var(--ink); font:15px/1.5 Inter, system-ui, sans-serif; }}
main {{ max-width:1180px; margin:0 auto; padding:32px 16px 80px }}
h1 {{ font-weight:600; margin:0 0 4px }} h2 {{ margin:0; font-weight:600 }} h2 span {{ color:var(--acc) }}
h3 {{ font-size:12px; text-transform:uppercase; letter-spacing:.08em; color:var(--mut); margin:22px 0 8px; font-weight:500 }}
p {{ color:var(--mut); margin:4px 0 0; max-width:70ch }}
nav {{ position:sticky; top:0; background:var(--bg); padding:10px 0; border-bottom:1px solid var(--line); z-index:2 }}
nav a {{ color:var(--ink); margin-right:12px; text-decoration:none; font-weight:500 }}
.palette {{ display:flex; gap:16px; flex-wrap:wrap; margin:16px 0 }}
.sw {{ display:flex; gap:8px; align-items:center }} .sw span {{ width:36px; height:36px; border-radius:50%; border:1px solid #fff2 }}
.sw code {{ font-size:11px; color:var(--mut) }}
.overview {{ display:grid; grid-template-columns:repeat(auto-fill,minmax(150px,1fr)); gap:12px; margin:20px 0 40px }}
.ov {{ background:{FI['deep-forest']}; border:1px solid var(--line); border-radius:12px; padding:12px; color:var(--ink); text-decoration:none; text-align:center; font-size:13px }}
.ov img {{ width:100%; display:block }}
.card {{ border-top:1px solid var(--line); padding:32px 0 }}
.hero {{ display:grid; grid-template-columns:1fr 1fr; gap:12px; margin-top:16px }}
.hero div {{ border-radius:12px; display:flex; justify-content:center; padding:12px }}
.hero img {{ width:min(256px,100%) }}
.sizes {{ display:flex; align-items:center; gap:18px; padding:12px 16px; border-radius:10px; margin-bottom:8px; overflow-x:auto }}
.avatars {{ display:flex; gap:14px; align-items:center; flex-wrap:wrap }}
.av {{ width:96px; height:96px }} .av.round {{ border-radius:50% }}
.locks {{ display:grid; grid-template-columns:1fr 1fr; gap:12px }}
.lock {{ border-radius:10px; padding:20px; display:flex; justify-content:center }} .lock img {{ height:64px; max-width:100% }}
.treat {{ display:grid; grid-template-columns:repeat(auto-fill,minmax(112px,1fr)); gap:10px }}
figure {{ margin:0 }} figcaption {{ font-size:11px; color:var(--mut); margin-top:4px }}
.tile {{ border-radius:10px; aspect-ratio:1; display:flex; align-items:center; justify-content:center }} .tile img {{ width:88% }}
.checker {{ background:repeating-conic-gradient(#2a332e 0 25%, #1a221e 0 50%) 0 0/16px 16px }}
@media (max-width:640px) {{ .hero, .locks {{ grid-template-columns:1fr }} }}
</style></head><body>
<nav><main style="padding:0 16px">{nav}</main></nav>
<main>
<h1>larecs — logo exploration</h1>
<p><a href="playground.html" style="color:var(--acc)">Open the interactive playground →</a></p>
<p>L monogram concepts L01–L10 (L01 reconstructs the preferred 6.1), tree-led L concepts T01–T07, plus one secondary concept each for Minimal Branch (B01) and Grid Forest (G01). Same scale, margins and backgrounds throughout.</p>
<div class="palette">{swatches}</div>
<div class="overview">{overview}</div>
{''.join(cards)}
</main></body></html>
"""


# --------------------------------------------------------------------------
# Main
# --------------------------------------------------------------------------


def write(path: Path, text: str):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)


# --------------------------------------------------------------------------
# Final assets (chosen concept)
# --------------------------------------------------------------------------

FINAL_ID = "V12"
FINAL_LIGHT = dict(a=FI["forest"], b=FI["forest"], c=FI["green"], d=FI["green"])
FINAL_DARK = dict(a=FI["ivory"], b=FI["ivory"], c=FI["light-green"], d=FI["light-green"])


def final_lockup(mark: Mark, colors, wm: Wordmark, editable=False) -> str:
    ih, pad = 120, 8
    x0, y0, x1, y1 = mark.bounds()
    k = (ih - 2 * pad) / (y1 - y0)
    iw = (x1 - x0) * k
    icon = render_mark(mark, colors, 0, origin=(pad + iw / 2, ih / 2), scale=k)
    th = ih * 0.46  # ascender height of the wordmark
    tx = pad + iw + ih * 0.2
    baseline = ih / 2 + th / 2
    if editable:
        text = (f'<text x="{_fmt(tx)}" y="{_fmt(baseline)}" font-family="Inter, sans-serif" '
                f'font-weight="500" font-size="{_fmt(th / 0.757)}" fill="{colors["a"]}">larecs</text>')
    else:
        text = wm.element(tx, baseline, th, colors["a"])
    return svg_doc(icon + "\n  " + text, tx + wm.width(th) + pad, ih, "larecs")


def write_final(wm: Wordmark, png: bool):
    c = next(c for c in CONCEPTS if c["id"] == FINAL_ID)
    mark, out = c["mark"], ROOT / "final"
    icon = lambda cols, bg=None, box_size=VIEW - 2 * MARGIN, shape=None: svg_doc(
        ({"circle": f'<circle cx="128" cy="128" r="128" fill="{bg}"/>\n  '}.get(shape, f'<rect width="256" height="256" fill="{bg}"/>\n  ') if bg else "")
        + render_mark(mark, cols, box_size), title="larecs")
    files = {
        "larecs-icon.svg": icon(FINAL_LIGHT),
        "larecs-icon-dark.svg": icon(FINAL_DARK),
        "larecs-icon-black.svg": icon(mono("#000000")),
        "larecs-icon-white.svg": icon(mono("#FFFFFF")),
        "larecs-icon-forest.svg": icon(mono(FI["forest"])),
        "larecs-icon-ivory.svg": icon(mono(FI["ivory"])),
        "larecs-avatar.svg": icon(FINAL_LIGHT, FI["ivory"], 180),
        "larecs-avatar-dark.svg": icon(FINAL_DARK, FI["deep-forest"], 180),
        "larecs-lockup.svg": final_lockup(mark, FINAL_LIGHT, wm),
        "larecs-lockup-dark.svg": final_lockup(mark, FINAL_DARK, wm),
        "larecs-lockup-editable.svg": final_lockup(mark, FINAL_LIGHT, wm, editable=True),
    }
    # Favicon follows the browser's colour scheme.
    body = render_mark(mark, FINAL_LIGHT, VIEW - 2 * 16)
    style = (f"<style>.r-a{{fill:{FI['forest']}}}.r-c{{fill:{FI['green']}}}"
             f"@media (prefers-color-scheme:dark){{.r-a{{fill:{FI['ivory']}}}.r-c{{fill:{FI['light-green']}}}}}</style>")
    files["favicon.svg"] = svg_doc(style + "\n  " + body.replace(f'fill="{FI["forest"]}" ', "").replace(f'fill="{FI["green"]}" ', ""),
                                   title="larecs")
    for name, text in files.items():
        write(out / name, text)
    if not png:
        return
    if not shutil.which("rsvg-convert"):
        print("warning: rsvg-convert not found; final PNGs and favicon.ico were not regenerated")
        return
    pdir = out / "png"
    pdir.mkdir(parents=True, exist_ok=True)
    run = lambda src, dst, z: subprocess.run(["rsvg-convert", "-w", str(z), "-h", str(z), "-o", str(pdir / dst),
                                              str(out / src)], check=True)
    for z in [16, 32, 48, 64, 128, 256, 512]:
        run("larecs-icon.svg", f"larecs-icon-{z}.png", z)
        run("larecs-icon-dark.svg", f"larecs-icon-dark-{z}.png", z)
    for z in [512, 1024]:
        run("larecs-avatar.svg", f"larecs-avatar-{z}.png", z)
        run("larecs-avatar-dark.svg", f"larecs-avatar-dark-{z}.png", z)
    for name in ["larecs-lockup", "larecs-lockup-dark"]:
        subprocess.run(["rsvg-convert", "-h", "240", "-o", str(pdir / f"{name}.png"), str(out / f"{name}.svg")], check=True)
    if shutil.which("magick"):
        subprocess.run(["magick", *(str(pdir / f"larecs-icon-{z}.png") for z in [16, 32, 48]), str(out / "favicon.ico")],
                       check=True)
    else:
        print("warning: magick (ImageMagick) not found; favicon.ico was not regenerated")


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--font", type=Path,
                    default=Path(os.environ.get("LARECS_WORDMARK_FONT",
                                                Path.home() / "Library/Fonts/Inter-VariableFont_opsz,wght.ttf")))
    ap.add_argument("--no-png", action="store_true", help="skip PNG rendering via rsvg-convert")
    args = ap.parse_args()

    wm = Wordmark(args.font)
    if wm.paths is None:
        print(f"warning: font {args.font} not found; wordmarks use editable text only")

    for c in CONCEPTS:
        c["mark"] = c["build"]()
        fam, cid = c["family"], c["id"]
        write(ROOT / "concepts" / fam / f"{cid}.svg", icon_svg(c, "color-dark"))
        for sch, spec in SCHEMES.items():
            write(ROOT / "variants" / spec["group"] / f"{cid}-{sch}.svg", icon_svg(c, sch))
        write(ROOT / "avatars" / f"{cid}-forest.svg", icon_svg(c, "color-dark", FI["forest"], box_size=AVATAR_BOX))
        write(ROOT / "avatars" / f"{cid}-deep.svg", icon_svg(c, "color-dark", FI["deep-forest"], box_size=AVATAR_BOX))
        write(ROOT / "avatars" / f"{cid}-ivory.svg", icon_svg(c, "color-light", FI["ivory"], box_size=AVATAR_BOX))
        write(ROOT / "wordmarks" / f"{cid}-dark.svg", lockup_svg(c, "color-dark", wm))
        write(ROOT / "wordmarks" / f"{cid}-light.svg", lockup_svg(c, "color-light", wm))
        write(ROOT / "wordmarks" / "editable" / f"{cid}-dark.svg", lockup_svg(c, "color-dark", wm, editable=True))

    mono = [c for c in CONCEPTS if c["family"] == "l-monogram"]
    write(ROOT / "previews" / "monogram-comparison.svg", comparison_board(mono, "L monogram concepts"))
    write(ROOT / "previews" / "tree-comparison.svg",
          comparison_board([c for c in CONCEPTS if c["family"] == "l-tree"], "Tree-led L concepts"))
    write(ROOT / "previews" / "concept-comparison.svg",
          comparison_board([c for c in CONCEPTS if c["id"] in ("L01", "L09", "B01", "G01")],
                           "Concept comparison: L monogram vs. secondary directions"))
    write(ROOT / "previews" / "size-test.svg", size_board(CONCEPTS))
    write(ROOT / "previews" / "index.html", gallery_html(CONCEPTS))

    if not args.no_png and not shutil.which("rsvg-convert"):
        print("warning: rsvg-convert not found; preview PNGs were not rendered (use --no-png to skip them)")
    if not args.no_png and shutil.which("rsvg-convert"):
        png = ROOT / "previews" / "png"
        png.mkdir(parents=True, exist_ok=True)
        for name in ["monogram-comparison", "tree-comparison", "concept-comparison", "size-test"]:
            subprocess.run(["rsvg-convert", "-o", str(png / f"{name}.png"),
                            str(ROOT / "previews" / f"{name}.svg")], check=True)
        for c in CONCEPTS:
            for z in [32, 256]:
                subprocess.run(["rsvg-convert", "-w", str(z), "-h", str(z), "-b", FI["deep-forest"],
                                "-o", str(png / f"{c['id']}-{z}.png"),
                                str(ROOT / "variants" / "dark" / f"{c['id']}-color-dark.svg")], check=True)
    write_final(wm, png=not args.no_png)
    print(f"generated {len(CONCEPTS)} concepts into {ROOT}")


if __name__ == "__main__":
    main()
