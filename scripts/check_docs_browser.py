"""Check rendered documentation in Chromium without a server or external requests."""

import json
import mimetypes
from urllib.parse import unquote, urljoin, urlsplit

from playwright.sync_api import sync_playwright

from check_docs import ROOT, Site


def check_browser(public=None, base=None):
    """Exercise narrow layouts, real search results, declarations, SVGs and aliases."""
    site = Site(public=public, base=base)
    output = ROOT / "output/docs/browser"
    output.mkdir(parents=True, exist_ok=True)
    errors = []
    checked = []

    def local(route):
        url = urlsplit(route.request.url)
        origin = urlsplit(site.base)
        if url.netloc != origin.netloc or not url.path.startswith(origin.path):
            errors.append(f"Unexpected external request: {url.geturl()}")
            route.abort()
            return
        path = site.public / unquote(url.path[len(origin.path):])
        if not path.suffix:
            path /= "index.html"
        if not path.is_file():
            errors.append(f"Missing browser resource: {url.path}")
            route.fulfill(status=404, body="Not found")
            return
        route.fulfill(body=path.read_bytes(), content_type=mimetypes.guess_type(path)[0] or "application/octet-stream")

    with sync_playwright() as playwright:
        browser = playwright.chromium.launch()
        page = browser.new_page(viewport={"width": 360, "height": 900}, device_scale_factor=1)
        page.route("**/*", local)
        page.on("pageerror", lambda error: errors.append(str(error)))
        page.on("console", lambda message: errors.append(message.text)
                if message.type in {"error", "warning"} else None)
        for width in (360, 768, 1440):
            page.set_viewport_size({"width": width, "height": 900})
            for route in ("start/first_simulation/", "reference/execution/",
                          "larecs/system/SystemContext/", "larecs/resource_adapter/ResourceAdapter/",
                          "inside/architecture/storage/", "inside/architecture/execution/"):
                page.goto(urljoin(site.base, route), wait_until="networkidle")
                page.locator("main").wait_for()
                page.locator("details").evaluate_all("items => items.forEach(item => item.open = true)")
                page.evaluate("document.fonts.ready")
                overflow = page.evaluate("document.documentElement.scrollWidth > innerWidth + 1")
                if overflow:
                    raise ValueError(f"Page overflows {width}px viewport: {route}")
                if route.startswith("larecs/"):
                    declarations = page.locator(".api-declaration pre")
                    if not declarations.count():
                        raise ValueError(f"Missing API declarations: {route}")
                    for declaration in declarations.all():
                        if declaration.evaluate("node => getComputedStyle(node).whiteSpace !== 'pre-wrap' || node.scrollWidth > node.clientWidth + 1"):
                            raise ValueError(f"API declaration does not wrap at {width}px: {route}")
                for image in page.locator("main img").all():
                    image.scroll_into_view_if_needed()
                    page.wait_for_function("image => image.complete && image.naturalWidth > 0", arg=image.element_handle())
                    try:
                        image.evaluate("image => image.decode()")
                    except Exception as error:
                        raise ValueError(f"Cannot decode {image.get_attribute('src')}: {errors}") from error
                checked.append({"route": route, "width": width})
                if width == 360 and route in {"start/first_simulation/", "larecs/system/SystemContext/"}:
                    page.screenshot(path=str(output / (route.strip("/").replace("/", "-") + ".png")), full_page=True)

        print("Browser: responsive layouts passed", flush=True)

        # Mobile navigation must expose both the primary route and the secondary links.
        page.set_viewport_size({"width": 360, "height": 900})
        page.goto(site.base, wait_until="networkidle")
        page.locator(".sl-menu-button").click()
        page.get_by_text("Inside Larecs", exact=True).first.wait_for(state="visible")
        page.get_by_role("link", name="Reference", exact=True).first.wait_for(state="visible")

        page.set_viewport_size({"width": 1440, "height": 900})
        page.goto(urljoin(site.base, "reference/"), wait_until="networkidle")
        page.locator('button[data-open-modal]').click()
        search = page.locator('.pagefind-ui__search-input')
        search.fill("SystemContext")
        results = page.locator('.pagefind-ui__result-link')
        results.first.wait_for(state="visible")
        results.first.click()
        page.wait_for_load_state("networkidle")
        if not page.url.startswith(site.base):
            raise ValueError(f"Search escapes deployment prefix: {page.url}")
        if urlsplit(page.url).fragment:
            if not page.evaluate("Boolean(document.getElementById(decodeURIComponent(location.hash.slice(1))))"):
                raise ValueError(f"Search navigates to a missing heading: {page.url}")

        print("Browser: search navigation passed", flush=True)

        # Check fragment retention in both ordinary aliases and case-only type aliases.
        for old, current, fragment in (("guide/installation/", "start/installation/", "troubleshooting"),
                                       ("larecs/SystemContext/", "larecs/system/SystemContext/", "run-1"),
                                       ("larecs/System/", "larecs/system/System/", "update")):
            page.goto(urljoin(site.base, old) + "#" + fragment, wait_until="networkidle")
            page.wait_for_url(urljoin(site.base, current) + "#" + fragment)
            if not page.evaluate("Boolean(document.getElementById(location.hash.slice(1)))"):
                raise ValueError(f"Redirect loses an incoming anchor: {old}#{fragment}")

        # Inspect the same fixed-palette SVG on a light canvas in both themes.
        page.goto(urljoin(site.base, "inside/architecture/storage/"), wait_until="networkidle")
        for dark in (False, True):
            page.evaluate("dark => document.documentElement.dataset.theme = dark ? 'dark' : 'light'", dark)
            image = page.locator("main img").first
            image.scroll_into_view_if_needed()
            if image.evaluate("image => getComputedStyle(image).backgroundColor") != "rgb(255, 255, 255)":
                raise ValueError("SVG labels lose their light canvas in the dark theme")
            page.screenshot(path=str(output / ("figures-dark.png" if dark else "figures-light.png")))
        browser.close()
    if errors:
        raise ValueError("Browser failures: " + "; ".join(sorted(set(errors))))
    (output / "checks.json").write_text(json.dumps(checked, indent=2) + "\n")
    print(f"Verified {len(checked)} Chromium layouts, search, mobile navigation, redirects and figure canvases")


if __name__ == "__main__":
    check_browser()
