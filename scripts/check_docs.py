"""Validate the complete published site, compatibility URLs and search data."""

import json
import os
import re
import unicodedata
from html.parser import HTMLParser
from pathlib import Path
from urllib.parse import unquote, urljoin, urlsplit

from check_api_reference import check as check_api

ROOT = Path(__file__).resolve().parent.parent


class Page(HTMLParser):
    """Collect navigable IDs, links, assets, redirects and readable text."""

    def __init__(self, text):
        super().__init__()
        self.ids = set()
        self.links = []
        self.images = []
        self.redirect = None
        self.url = None
        self.text = []
        self.feed(text)

    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        if "id" in attrs:
            self.ids.add(attrs["id"])
        if tag in {"a", "link"} and attrs.get("href"):
            self.links.append(attrs["href"])
        if tag in {"img", "script", "source"} and attrs.get("src"):
            self.links.append(attrs["src"])
        if tag == "img":
            self.images.append(attrs)
        if tag == "meta" and attrs.get("http-equiv", "").lower() == "refresh":
            self.redirect = attrs["content"].split("url=", 1)[1].strip()
        if tag == "meta" and attrs.get("name") == "docs-url":
            self.url = attrs["content"]

    def handle_data(self, data):
        self.text.append(data)


def markdown_ids(text: str) -> set[str]:
    """Resolve GitHub heading fragments and explicit repository anchors offline."""
    ids = set(re.findall(r'<(?:a|span)\s+id="([^"]+)"', text))
    counts = {}
    fenced = False
    for line in text.splitlines():
        if line.lstrip().startswith(("```", "~~~")):
            fenced = not fenced
        if fenced or not re.match(r"^#{1,6} ", line):
            continue
        heading = re.sub(r"^#+\s+", "", line).strip().lower()
        heading = re.sub(r"[^\w\- ]", "", unicodedata.normalize("NFC", heading)).replace(" ", "-")
        count = counts.get(heading, 0)
        counts[heading] = count + 1
        ids.add(heading + (f"-{count}" if count else ""))
    return ids


class Site:
    """Resolve links as a browser would, including redirects and deployment prefixes."""

    def __init__(self, root=ROOT, public=None, base=None):
        self.root = root
        self.public = public or root / "docs/site/public"
        config = (root / "docs/site/hugo.yaml").read_text()
        self.base = base or os.environ.get("HUGO_BASEURL") or re.search(r"(?m)^baseURL: (.+)$", config)[1].strip()
        self.origin = urlsplit(self.base)
        self.pages = {path: Page(path.read_text()) for path in self.public.rglob("*.html")}
        self.api = json.loads((root / "docs/site/data/api.json").read_text())

    def resolve(self, href, page_url=None, seen=()):
        """Reject missing paths, stale anchors, preview escapes and redirect cycles."""
        url = urlsplit(urljoin(page_url or self.base, href))
        if url.scheme not in {"http", "https"}:
            return
        if url.netloc != self.origin.netloc:
            self.repository_link(url)
            return
        if not url.path.startswith(self.origin.path):
            raise ValueError(f"Link escapes deployment prefix {self.origin.path}: {url.geturl()}")
        relative = unquote(url.path[len(self.origin.path):])
        if relative in self.api.get("case_redirects", {}):
            path = self.public / relative / "index.html"
            if not path.is_file() or "data-legacy-redirect" not in path.read_text():
                raise ValueError(f"Missing case-compatible redirect: {relative}")
            return self.resolve(self.api["case_redirects"][relative] +
                                ("#" + url.fragment if url.fragment else ""), seen=seen)
        path = self.public / relative
        if not path.suffix:
            path = path / "index.html"
        if not path.is_file():
            raise ValueError(f"Missing site target: {url.geturl()} (from {page_url})")
        page = self.pages.get(path)
        if page and page.redirect:
            if path in seen:
                raise ValueError(f"Redirect cycle: {url.geturl()}")
            target = page.redirect
            if url.fragment and not urlsplit(target).fragment:
                target += "#" + url.fragment
            return self.resolve(target, url.geturl(), seen + (path,))
        if page and url.fragment and unquote(url.fragment) not in page.ids:
            raise ValueError(f"Missing site anchor: {url.geturl()} (from {page_url})")

    def repository_link(self, url):
        """Check local repository evidence paths and source/Markdown fragments."""
        match = re.match(r"^/larecs/larecs/(blob|tree)/([^/]+)/(.*)$", url.path)
        if url.netloc != "github.com" or not match:
            return
        kind, revision, relative = match.groups()
        path = self.root / unquote(relative)
        if not path.exists():
            raise ValueError(f"Missing repository evidence: {url.geturl()}")
        if kind == "tree" or not url.fragment:
            return
        fragment = unquote(url.fragment)
        line = re.fullmatch(r"L(\d+)(?:-L(\d+))?", fragment)
        if line:
            if not 1 <= int(line[1]) <= int(line[2] or line[1]) <= len(path.read_text().splitlines()):
                raise ValueError(f"Invalid source line: {url.geturl()}")
        elif path.suffix == ".md" and fragment not in markdown_ids(path.read_text()):
            raise ValueError(f"Missing repository anchor: {url.geturl()}")

    def check(self):
        """Validate all HTML links/assets, old incoming URLs and indexed destinations."""
        if not self.pages:
            raise ValueError("Missing generated site")
        for path, page in self.pages.items():
            relative = path.relative_to(self.public).as_posix().removesuffix("index.html")
            page_url = urljoin(self.base, page.url or relative)
            for href in page.links:
                self.resolve(href, page_url)
            for attrs in page.images:
                if not attrs.get("alt", "").strip():
                    raise ValueError(f"Missing image alt text: {path}: {attrs.get('src')}")
        legacy = json.loads((self.root / "scripts/docs_legacy_urls.json").read_text())
        for route, anchors in legacy.items():
            self.resolve(route)
            for anchor in anchors:
                self.resolve(route + "#" + anchor)
        for route, target in self.api.get("redirects", {}).items():
            self.resolve(route)
            page = self.pages[self.public / target / "index.html"]
            for anchor in page.ids:
                self.resolve(route + "#" + anchor)
        indexes = list(self.public.glob("*.search-data*.json"))
        if len(indexes) != 1:
            raise ValueError(f"Expected one search index, found {indexes}")
        search = json.loads(indexes[0].read_text())
        for route, data in search.items():
            self.resolve(route)
            for heading in data["data"]:
                fragment = heading.split("#", 1)[0]
                if fragment:
                    self.resolve(route + "#" + fragment)
        for path, page in self.pages.items():
            if page.redirect or path.name != "index.html" or path.parent == self.public:
                continue
            route = page.url
            if route not in search:
                raise ValueError(f"Published page missing from search: {route}")
        print(f"Verified {len(self.pages)} HTML pages, links/assets/anchors, "
              f"{len(legacy)} legacy routes and {len(search)} indexed pages")


def check(root=ROOT, public=None, base=None):
    """Run generated API and ordinary site checks against the same output."""
    check_api(root, public=public, base=base)
    Site(root, public, base).check()


if __name__ == "__main__":
    check()
