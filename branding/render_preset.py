# /// script
# requires-python = ">=3.11"
# dependencies = ["shapely>=2.0", "fonttools>=4.50"]
# ///
"""Render a logo preset from a playground share link to PNG.

Reads text (for example a pull request comment) from the COMMENT_BODY
environment variable, takes the first `#preset=<base64url JSON>` fragment in
it, and renders that preset: the mark on its background, on its second
background, and at 64, 32 and 16 px. The text is untrusted: parameters are
clamped to the playground's slider ranges and colours must be six-digit hex.

Usage:
    COMMENT_BODY='...' uv run branding/render_preset.py OUT.png

Exits 0 without writing OUT.png when the text holds no usable preset.
Needs rsvg-convert.
"""

from __future__ import annotations

import base64
import json
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import generate_logos as gl  # noqa: E402

PRESET_RE = re.compile(r"#preset=([A-Za-z0-9_-]{1,8000})")
HEX_RE = re.compile(r"^#[0-9a-fA-F]{6}$")
DEFAULT_COLORS = dict(a="#F1E9D2", b="#CBC1A4", c="#91C96B", d="#4E8B58", bg="#0B1712", alt="#1F5138")


def parse(text: str) -> dict | None:
    """Return a sanitised preset from the first share link in `text`."""
    m = PRESET_RE.search(text)
    if not m:
        return None
    raw = m.group(1)
    try:
        preset = json.loads(base64.urlsafe_b64decode(raw + "=" * (-len(raw) % 4)))
    except (ValueError, UnicodeDecodeError):
        return None
    if not isinstance(preset, dict) or preset.get("concept") != "V12":
        return None
    given = preset.get("params") if isinstance(preset.get("params"), dict) else {}
    params = {}
    for key, (lo, hi) in gl.SPRUCE_RANGES.items():
        v = given.get(key, gl.V12[key])
        if isinstance(v, bool) or not isinstance(v, (int, float)) or v != v:
            v = gl.V12[key]
        params[key] = min(hi, max(lo, float(v)))
    params["n"] = int(round(params["n"]))
    colors = dict(DEFAULT_COLORS)
    given = preset.get("colors") if isinstance(preset.get("colors"), dict) else {}
    for role in colors:
        if isinstance(given.get(role), str) and HEX_RE.match(given[role]):
            colors[role] = given[role]
    if preset.get("mono") is True:
        colors.update(b=colors["a"], c=colors["a"], d=colors["a"])
    return dict(params=params, colors=colors)


def board(preset: dict) -> str:
    """Two large tiles and a small-size strip, as one SVG document."""
    mark = gl.spruce_l(preset["params"])
    cols = preset["colors"]
    roles = {k: cols[k] for k in "abcd"}
    icon = gl.svg_doc(gl.render_mark(mark, roles, 192), title="larecs")
    parts = []
    for i, bg in enumerate([cols["bg"], cols["alt"]]):
        x = 16 + i * 416
        parts.append(f'<rect x="{x}" y="16" width="400" height="400" rx="24" fill="{bg}"/>')
        parts.append(gl.nest(icon, x, 16, 400))
    x = 848
    parts.append(f'<rect x="{x}" y="16" width="176" height="400" rx="24" fill="{cols["bg"]}"/>')
    y = 48
    for z in [64, 32, 16]:
        parts.append(gl.nest(icon, x + 88 - z / 2, y, z))
        y += z + 48
    return gl.svg_doc("\n  ".join(parts), 1040, 432, "larecs logo variation")


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__, file=sys.stderr)
        return 2
    preset = parse(os.environ.get("COMMENT_BODY", ""))
    if preset is None:
        print("no usable preset found")
        return 0
    with tempfile.NamedTemporaryFile("w", suffix=".svg", delete=False) as f:
        f.write(board(preset))
    subprocess.run(["rsvg-convert", "-o", sys.argv[1], f.name], check=True)
    os.unlink(f.name)
    print(f"rendered {sys.argv[1]}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
