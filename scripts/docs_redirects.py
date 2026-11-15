"""Preserve case-only legacy aliases on both APFS and case-sensitive hosts."""

import html
import json
from urllib.parse import urljoin, urlsplit


def write_case_redirects(root, public, base):
    """Keep module indexes intact when a legacy type alias differs only in case."""
    data = json.loads((root / "docs/site/data/api.json").read_text())
    for route, target in data["case_redirects"].items():
        path = public / route / "index.html"
        module = public / route.lower() / "index.html"
        destination = urljoin(base, target)
        script = (f'<script data-legacy-redirect>if (location.pathname === '
                  f'{json.dumps(urlsplit(urljoin(base, route)).path)}) '
                  f'location.replace({json.dumps(destination)} + location.hash);</script>')
        if path.exists() and path.samefile(module):
            text = module.read_text()
            if "data-legacy-redirect" in text:
                raise ValueError("Case redirects require a clean Astro destination")
            module.write_text(text.replace("</body>", script + "</body>"))
        else:
            path.parent.mkdir(parents=True, exist_ok=True)
            escaped = html.escape(destination, quote=True)
            path.write_text(f'<!doctype html><html lang="en"><head><meta charset="utf-8">'
                            f'<title>Page moved</title><link rel="canonical" href="{escaped}">'
                            f'<meta http-equiv="refresh" content="0; url={escaped}">'
                            f'{script}</head><body><a href="{escaped}">Continue to the current page</a>.'
                            f'</body></html>\n')
