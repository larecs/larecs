"""Regression checks for documentation publishing failures and compatibility."""

import json
import tempfile
import unittest
from pathlib import Path

from api_reference import ROOT, source_locations
from check_docs import Page, Site, check
from doc_examples import coverage, inventory, regions
from render_docs import Renderer


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

    def test_prose_label_is_not_an_executable_listing(self):
        with (self.root / "docs/src/example.md").open("a") as file:
            file.write('Use `doctest="not_a_test"` for an inline example.\n')
        self.assertEqual(len(inventory(self.root)), 2)

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

    def test_renderer_rejects_missing_dependencies(self):
        renderer = Renderer()
        for content in ('{{< api DoesNotExist >}}',
                        '{{< example file="missing.mojo" >}}',
                        '{{< example file="particles/movement.mojo" region="missing" >}}'):
            with self.subTest(content=content), self.assertRaises((ValueError, KeyError)):
                renderer.shortcodes(content)

    def test_missing_api_documentation_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "Missing declaration documentation"):
            Renderer().contract({"kind": "struct", "name": "Undocumented"}, "example", Path("example"))

    def test_duplicate_anchors_are_detected(self):
        page = Page('<h2 id="same">Heading</h2><a id="same"></a>')
        self.assertEqual(page.duplicate_ids, {"same"})

    def test_region_indentation_matches_program(self):
        excerpt = regions('# region inner\n    a()\n    if True:\n        b()\n# endregion inner')['inner']
        self.assertEqual(excerpt, 'a()\nif True:\n    b()')

    def test_source_locations_ignore_examples_and_respect_type_ownership(self):
        text = 'struct First:\n    """Example:\n    def method(): pass\n    """\n    def actual(self): pass\nstruct Second:\n    def method(self): pass\n'
        locations = source_locations(text)
        self.assertNotIn(("First", "method"), locations)
        self.assertEqual(locations[("First", "actual")], 5)
        self.assertEqual(locations[("Second", "method")], 7)


if __name__ == "__main__":
    unittest.main()
