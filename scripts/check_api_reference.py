"""Check compiler-derived symbol targets and guide links in the built site."""

import json
import os
import re
from html.parser import HTMLParser
from pathlib import Path
from urllib.parse import unquote, urljoin, urlsplit

ROOT = Path(__file__).resolve().parent.parent


class Page(HTMLParser):
    """Collect anchors and hyperlinks from a rendered page."""

    def __init__(self, text):
        """Parse HTML text into anchor and link collections.

        Args:
            text: Rendered HTML to inspect.
        """
        super().__init__()
        self.ids = set()
        self.links = []
        self.feed(text)

    def handle_starttag(self, tag, attrs):
        """Collect IDs and anchor destinations.

        Args:
            tag: Element name.
            attrs: Element attributes.
        """
        attrs = dict(attrs)
        if "id" in attrs:
            self.ids.add(attrs["id"])
        if tag == "a" and "href" in attrs:
            self.links.append(attrs["href"])


def check(root: Path = ROOT, public: Path | None = None, base: str | None = None) -> None:
    """Reject nonexistent symbol targets and broken reference links.

    Args:
        root: Repository containing the generated site and symbol map.

    Raises:
        ValueError: If a page or anchor is missing.
    """
    public = public or root / "docs/site/public"
    data = json.loads((root / "docs/site/data/api.json").read_text())
    pages = {}

    def resolve(target):
        """Check a site-relative page and optional fragment."""
        parsed = urlsplit(target)
        path = public / unquote(parsed.path).strip("/")
        path = path / "index.html" if not path.suffix else path
        if not path.exists():
            raise ValueError(f"Missing API page: {target}")
        if path not in pages:
            pages[path] = Page(path.read_text())
        if parsed.fragment and unquote(parsed.fragment) not in pages[path].ids:
            raise ValueError(f"Missing API anchor: {target}")

    for target in {item["target"] for item in data["symbols"].values()}:
        resolve(target)
    for name, item in data["symbols"].items():
        source = root / item["source"]
        lines = source.read_text().splitlines()
        line = item["line"]
        symbol = item["source_symbol"]
        if not 1 <= line <= len(lines) or not re.search(
            r"\b(?:def|struct|trait|comptime) " + re.escape(symbol) + r"(?:\W|$)", lines[line - 1]
        ):
            raise ValueError(f"Invalid symbol source: {name}: {item}")
        expected = f"https://github.com/larecs/larecs/blob/{data['revision']}/{item['source']}#L{line}"
        if item["source_url"] != expected:
            raise ValueError(f"Unpinned symbol source: {name}")
    # Resolve relative links with the same trailing-slash behavior as a browser.
    base = base or os.environ.get("DOCS_BASE_URL") or "https://larecs.github.io/larecs/dev/"
    base_path = urlsplit(base).path
    for page in (public / "reference").rglob("index.html"):
        page_url = urljoin(base, str(page.parent.relative_to(public)) + "/")
        for href in Page(page.read_text()).links:
            target = urlsplit(urljoin(page_url, href))
            if target.netloc == urlsplit(base).netloc and target.path.startswith(base_path):
                resolve(target.path[len(base_path):] + ("#" + target.fragment if target.fragment else ""))
    print(f"Verified {len(data['symbols'])} symbol names and reference links")


if __name__ == "__main__":
    check()
