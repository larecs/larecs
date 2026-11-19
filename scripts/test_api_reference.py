"""Integration checks for the compiler/Starlight reference build.

Run after `pixi run build-docs` with the scripts Pixi test-api-reference task.
"""

import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

from check_api_reference import ROOT
from check_api_reference import Page, check
from check_docs import check as check_site, Page as SitePage
from check_docs_browser import check_browser


class ReferenceTests(unittest.TestCase):
    """Exercise real generated declarations, aliases and failure gates."""

    def test_real_symbol_targets(self):
        """Resolve root, module-only, alias and overloaded declarations."""
        check()
        data = json.loads((ROOT / "docs/site/data/api.json").read_text())
        symbols = data["symbols"]
        self.assertEqual(symbols["World"], symbols["larecs.world.World"])
        self.assertIn("larecs.iteration.LockedEntityRange", symbols)
        self.assertIn("larecs.component.ComponentType", symbols)
        self.assertIn("SystemContext.run-1", symbols)
        self.assertNotIn("larecs.Replacer", symbols)

    def test_missing_anchor_is_rejected(self):
        """A valid page cannot conceal a stale symbol fragment."""
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "docs/site/data").mkdir(parents=True)
            (root / "docs/site/public/example").mkdir(parents=True)
            (root / "docs/site/public/example/index.html").write_text('<h1 id="present">Example</h1>')
            (root / "docs/site/data/api.json").write_text(json.dumps({"symbols": {"Example": {"target": "example/#missing"}}}))
            with self.assertRaisesRegex(ValueError, "Missing API anchor"):
                check(root)

    def test_preview_base_path(self):
        base = "https://example.test/deploy/pr-preview/pr-999/"
        command = ["node", "docs/site/run.mjs", "render"]
        try:
            subprocess.run(command, cwd=ROOT, env=os.environ | {"DOCS_BASE_URL": base},
                           check=True, stdout=subprocess.DEVNULL)
            check_site(base=base)
            check_browser(base=base)
        finally:
            subprocess.run(command, cwd=ROOT, check=True, stdout=subprocess.DEVNULL)

    def test_rendered_contracts_and_sources(self):
        """Keep constraints, exact overloads and pinned source links visible."""
        data = json.loads((ROOT / "docs/site/data/api.json").read_text())
        html = (ROOT / "docs/site/public/larecs/system/SystemContext/index.html").read_text()
        self.assertIn("Constraints", html)
        self.assertIn("Exact declaration", html)
        self.assertIn('id="run-0"', html)
        self.assertIn('id="run-1"', html)
        self.assertIn(f"/blob/{data['revision']}/src/larecs/system.mojo", html)
        legacy = (ROOT / "docs/site/public/larecs/SystemContext/index.html").read_text()
        self.assertIn("/larecs/system/SystemContext/", legacy)
        self.assertTrue(Page(html).ids)
        declaration = json.loads((ROOT / "docs/src/larecs.json").read_text())["decl"]
        module = next(m for m in declaration["modules"] if m["name"] == "system")
        context = next(s for s in module["structs"] if s["name"] == "SystemContext")
        run = next(f for f in context["functions"] if f["name"] == "run")
        text = "".join(SitePage(html).text)
        self.assertIn(run["overloads"][1]["signature"], text)
        module = next(m for m in declaration["modules"] if m["name"] == "filter")
        filter_type = next(s for s in module["structs"] if s["name"] == "Filter")
        get_mask = next(f for f in filter_type["functions"] if f["name"] == "get_bitmask_filter")
        filter_html = (ROOT / "docs/site/public/larecs/filter/Filter/index.html").read_text()
        self.assertIn(get_mask["overloads"][0]["signature"], ''.join(SitePage(filter_html).text))
        resources = (ROOT / "docs/site/public/larecs/resource/ResourceStorage/index.html").read_text()
        self.assertIn("Note:", resources)
        self.assertIn("re-obtain it", resources)


if __name__ == "__main__":
    unittest.main()
