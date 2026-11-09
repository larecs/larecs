"""Integration checks for the compiler/Modo/Hugo reference build.

Run after `pixi run build-docs` with the scripts Pixi test-api-reference task.
"""

import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

from api_reference import ROOT, root_exports
from check_api_reference import Page, check
from check_docs import check as check_site, Page as SitePage
from docs_redirects import write_case_redirects
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

    def test_export_drift_is_rejected(self):
        """Reject a stale manual export independently of compiler success."""
        source = (ROOT / "src/larecs/__init__.mojo").read_text()
        root_exports(source)
        with self.assertRaisesRegex(ValueError, "Exports list differs"):
            root_exports(source.replace(" - world.World\n", ""))

    def test_missing_anchor_is_rejected(self):
        """A valid page cannot conceal a stale symbol fragment."""
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "docs/site/data").mkdir(parents=True)
            (root / "docs/site/hugo.yaml").write_text("baseURL: https://example.test/docs/\n")
            (root / "docs/site/public/example").mkdir(parents=True)
            (root / "docs/site/public/example/index.html").write_text('<h1 id="present">Example</h1>')
            (root / "docs/site/data/api.json").write_text(json.dumps({"symbols": {"Example": {"target": "example/#missing"}}}))
            with self.assertRaisesRegex(ValueError, "Missing API anchor"):
                check(root)

    def test_unknown_symbols_fail_hugo(self):
        """Reject unknown shortcodes in the actual renderer."""
        fixture = ROOT / "docs/site/content/reference/unknown-symbol-test.md"
        try:
            fixture.write_text('---\ntitle: Negative fixture\n---\n{{< api DoesNotExist >}}\n')
            with tempfile.TemporaryDirectory() as destination:
                result = subprocess.run(
                    ["hugo", "-s", str(ROOT / "docs/site"), "--destination", destination],
                    capture_output=True, text=True,
                )
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('Unknown API symbol "DoesNotExist"', result.stdout + result.stderr)
        finally:
            fixture.unlink(missing_ok=True)

    def test_preview_base_path(self):
        """Render API links under a deployment prefix different from production."""
        with tempfile.TemporaryDirectory() as destination:
            base = "https://example.test/deploy/pr-preview/pr-999/"
            subprocess.run(
                ["hugo", "-s", str(ROOT / "docs/site"), "--baseURL",
                 base, "--destination", destination],
                capture_output=True, text=True, check=True,
                env=os.environ | {"HUGO_BASEURL": base},
            )
            html = (Path(destination) / "reference/identity/index.html").read_text()
            self.assertTrue('href="/deploy/pr-preview/pr-999/larecs/world/World/"' in html,
                            "API link lacks the alternate deployment prefix")
            write_case_redirects(ROOT, Path(destination), base)
            check_site(ROOT, Path(destination), base)
            check_browser(Path(destination), base)

    def test_rendered_contracts_and_sources(self):
        """Keep constraints, exact overloads and pinned source links visible."""
        data = json.loads((ROOT / "docs/site/data/api.json").read_text())
        html = (ROOT / "docs/site/public/larecs/system/SystemContext/index.html").read_text()
        self.assertIn("Constraints:", html)
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
        resources = (ROOT / "docs/site/public/larecs/resource/ResourceStorage/index.html").read_text()
        self.assertIn("Note:", resources)
        self.assertIn("re-obtain it", resources)


if __name__ == "__main__":
    unittest.main()
