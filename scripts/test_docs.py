"""Regression checks for documentation publishing failures and compatibility."""

import asyncio
import copy
import io
import json
import subprocess
import tempfile
import unittest
from pathlib import Path

from api_reference import ROOT, source_locations
from check_docs import Page, Site, check
from doc_examples import coverage, inventory, regions
from docs import _modo_executable, _relay, _DOC_WARNING_RE, _check


class ExampleTests(unittest.TestCase):
    """Exercise partial extraction loss and checked-excerpt failure cases."""

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        for path in ("docs/src", "docs/test", "examples/particles"):
            (self.root / path).mkdir(parents=True)
        (self.root / "docs/src/larecs.json").write_text('{"decl": {"name": "larecs", "kind": "package"}}')
        (self.root / "examples/particles/example.mojo").write_text('def main():\n    pass\n')
        (self.root / "docs/src/example.md").write_text('```mojo {doctest="one" global=true}\ndef main():\n    pass\n```\n')
        (self.root / "docs/test/example_one_test.mojo").write_text('def main():\n    pass\n')

    def test_partial_extraction_loss(self):
        self.assertEqual(len(inventory(self.root)), 2)
        with (self.root / "docs/src/example.md").open("a") as file:
            file.write('\n```mojo {doctest="two" global=true}\ndef main():\n    pass\n```\n')
        with self.assertRaisesRegex(ValueError, "missing=.*example_two_test"):
            inventory(self.root)

    def test_unexpected_test_and_unchecked_listing(self):
        (self.root / "docs/test/stale.mojo").write_text('def main():\n    pass\n')
        with self.assertRaisesRegex(ValueError, "unexpected=.*stale"):
            inventory(self.root)
        (self.root / "docs/test/stale.mojo").unlink()
        (self.root / "docs/src/example.md").write_text('```mojo\npass\n```\n')
        with self.assertRaisesRegex(ValueError, "Unchecked Mojo listing"):
            inventory(self.root)

    def test_excerpt_source_cannot_escape_execution(self):
        extra = self.root / "examples/extra.mojo"
        extra.write_text('# region body\ndef main():\n    pass\n# endregion body\n')
        page = self.root / "docs/src/extra.md"
        page.write_text('{{< example file="extra.mojo" region="body" >}}')
        self.assertIn(extra, inventory(self.root))
        extra.unlink()
        with self.assertRaisesRegex(ValueError, "Missing example"):
            inventory(self.root)

    def test_broken_regions(self):
        for text in ('# region one\npass', '# endregion one',
                     '# region one\n# endregion one',
                     '# region one\npass\n# endregion one\n# region one\npass\n# endregion one'):
            with self.subTest(text=text), self.assertRaises(ValueError):
                regions(text)

    def test_execution_is_separate_from_hardware_skip(self):
        program = self.root / "examples/particles/example.mojo"
        program.write_text('def main():\n    comptime if has_accelerator():\n        print("PASS: actual device parity")\n')
        prefix = '=== examples/particles/example.mojo ===\n'
        passed = coverage(prefix + 'PASS: actual device parity\n', [program], self.root)
        skipped = coverage(prefix + 'SKIP: no accelerator\n', [program], self.root)
        self.assertEqual(len(passed["actual_device_execution"]), 1)
        self.assertFalse(passed["hardware_skips"])
        self.assertFalse(skipped["actual_device_execution"])
        self.assertEqual(len(skipped["hardware_skips"]), 1)
        with self.assertRaisesRegex(ValueError, "Missing or ambiguous"):
            coverage(prefix + 'PASS\n', [program], self.root)


class PublishingTests(unittest.TestCase):
    """Check real generator warning gates, deployed URLs, status and search."""

    def test_site_and_legacy_urls(self):
        check()

    def test_ordinary_link_anchor_and_prefix_failures(self):
        site = Site()
        for target, message in (("guide/missing/", "Missing site target"),
                                ("start/first_simulation/#missing", "Missing site anchor"),
                                ("/outside/", "escapes deployment prefix")):
            with self.subTest(target=target), self.assertRaisesRegex(ValueError, message):
                site.resolve(target)

    def test_modo_warnings_are_errors(self):
        original = json.loads((ROOT / "docs/src/larecs.json").read_text())
        for missing in (True, False):
            data = copy.deepcopy(original)
            module = data["decl"]["modules"][1]
            module["summary"] = "" if missing else "[UnknownDocumentationSymbol]"
            module["description"] = ""
            with self.subTest(missing_description=missing), tempfile.TemporaryDirectory() as directory:
                fixture = Path(directory) / "fixture.json"
                fixture.write_text(json.dumps(data))
                result = subprocess.run(
                    [_modo_executable(), "build", "--bare", "--input", str(fixture),
                     "--output", str(Path(directory) / "content"), "--tests", ""],
                    cwd=ROOT, capture_output=True, text=True,
                )
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn("missing docstrings" if missing else "Can't resolve cross ref",
                              result.stdout + result.stderr)

    def test_hugo_example_and_warning_failures(self):
        fixture = ROOT / "docs/site/content/negative-fixture.md"
        shortcode = ROOT / "docs/site/layouts/shortcodes/negative-warning.html"
        try:
            shortcode.write_text('{{ warnf "intentional documentation warning" }}')
            for content, diagnostic in (
                ('{{< example file="missing.mojo" >}}', 'not found under examples/'),
                ('{{< example file="particles/movement.mojo" region="missing" >}}', 'region "missing" not found'),
                ('{{< negative-warning >}}', 'intentional documentation warning'),
            ):
                with self.subTest(content=content), tempfile.TemporaryDirectory() as directory:
                    fixture.write_text('---\ntitle: Negative fixture\n---\n' + content)
                    result = subprocess.run(["hugo", "-s", str(ROOT / "docs/site"),
                                             "--panicOnWarning", "--destination", directory],
                                            capture_output=True, text=True)
                    warned = any(_DOC_WARNING_RE.match(line.encode()) for line in (result.stdout + result.stderr).splitlines())
                    with self.assertRaises(SystemExit):
                        _check(result.returncode, warned, "Hugo negative fixture")
                    self.assertIn(diagnostic, result.stdout + result.stderr)
        finally:
            fixture.unlink(missing_ok=True)
            shortcode.unlink(missing_ok=True)

    def test_wrapper_propagates_script_errors_and_doc_warnings(self):
        async def relay(line):
            stream = asyncio.StreamReader()
            stream.feed_data(line)
            stream.feed_eof()
            return await _relay(stream, io.TextIOWrapper(io.BytesIO()))

        for line in (b"Error: in script post-test: exit status 1\n", b"WARNING: broken cross ref\n",
                     b"WARN  intentional documentation warning\n",
                     b"\x1b[33mWARNING: colored diagnostic\x1b[0m\n",
                     b"src/larecs/example.mojo:2:3: warning: undocumented parameter\n"):
            self.assertTrue(asyncio.run(relay(line)))

    def test_navigation_status_and_search_contracts(self):
        public = ROOT / "docs/site/public"
        home = (public / "index.html").read_text()
        for label, route in (("Start", "start"), ("Guides", "guide"), ("Reference", "reference")):
            self.assertIn(f'title="{label}"', home)
            self.assertIn(f'/{route}', home)
        for text in ("Documentation version", "Development · Larecs", "experimental APIs",
                     "Architecture", "Development", "Menu"):
            self.assertIn(text, home)
        search = json.loads(next(public.glob("*.search-data*.json")).read_text())
        execution = next(v for k, v in search.items() if k.endswith('/larecs/system/SystemContext/'))
        text = json.dumps(execution)
        self.assertIn("Constraints:", text)
        self.assertIn("device-safe component and resource types", text)
        resource = next(v for k, v in search.items() if k.endswith('/larecs/resource/ResourceStorage/'))
        self.assertIn("re-obtain it", json.dumps(resource))

    def test_source_locations_ignore_examples_and_respect_type_ownership(self):
        text = 'struct First:\n    """Example:\n    def method(): pass\n    """\n    def actual(self): pass\nstruct Second:\n    def method(self): pass\n'
        locations = source_locations(text)
        self.assertNotIn(("First", "method"), locations)
        self.assertEqual(locations[("First", "actual")], 5)
        self.assertEqual(locations[("Second", "method")], 7)


if __name__ == "__main__":
    unittest.main()
