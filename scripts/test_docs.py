"""Regression checks for documentation publishing failures and compatibility."""

import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from check_docs import Page, Site, check
from build_figures import check_inventory
from docs_versions import build_manifest, releases, update_pages
from doc_examples import coverage, doctest_runner, inventory, regions, source_doctests


class RunnerTests(unittest.TestCase):
    """Reject changed upstream source before building a documentation tool."""

    def test_runner_rejects_source_checksum_mismatch(self):
        with tempfile.TemporaryDirectory() as directory, \
                patch("doc_examples.platform.system", return_value="Linux"), \
                patch("doc_examples.urllib.request.urlopen") as download, \
                patch("doc_examples.subprocess.run") as build:
            download.return_value.__enter__.return_value.read.return_value = b"changed source"
            with self.assertRaisesRegex(ValueError, "source checksum differs"):
                doctest_runner(Path(directory))
            build.assert_not_called()


class VersionTests(unittest.TestCase):
    """Keep release folders immutable and the version index accurate."""

    def site(self, root, *folders):
        for folder in folders:
            (root / folder).mkdir(parents=True)
            (root / folder / "index.html").write_text(folder)

    def test_versions_sort_prereleases_before_finals(self):
        self.assertEqual(releases(["v1.0.0", "v1.0.0rc1", "v1.0.0b2", "v1.0.0b10", "pre-gpu", "nightly-published"]),
                         ["v1.0.0", "v1.0.0rc1", "v1.0.0b10", "v1.0.0b2"])

    def test_manifest_prefers_newest_build_and_links_older_tags(self):
        with tempfile.TemporaryDirectory() as directory:
            pages = Path(directory)
            self.site(pages, "dev", "v1.0.0b1", "v1.0.0")
            manifest = build_manifest(pages, ["v0.4.0", "v1.0.0", "v1.0.0b1", "pre-gpu"], "owner/repo")
            self.assertEqual(manifest["default"], "v1.0.0/")
            self.assertEqual([entry["id"] for entry in manifest["versions"]], ["dev", "v1.0.0", "v1.0.0b1", "v0.4.0"])
            self.assertEqual(manifest["versions"][-1]["url"], "https://github.com/owner/repo/tree/v0.4.0")

    def test_root_uses_development_before_first_release(self):
        with tempfile.TemporaryDirectory() as directory:
            pages = Path(directory)
            self.site(pages, "dev", "pr-preview/pr-1")
            update_pages(pages, ["v0.4.0"], "owner/repo")
            self.assertIn('url=dev/', (pages / "index.html").read_text())
            self.assertTrue((pages / "pr-preview/pr-1/index.html").is_file())

    def test_existing_release_is_not_replaced(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            pages, first, second = root / "pages", root / "first", root / "second"
            pages.mkdir()
            self.site(root, "first", "second")
            (second / "index.html").write_text("changed")
            self.assertTrue(update_pages(pages, ["v1.0.0"], "owner/repo", first, "1.0.0"))
            self.assertFalse(update_pages(pages, ["v1.0.0"], "owner/repo", second, "1.0.0"))
            self.assertEqual((pages / "v1.0.0/index.html").read_text(), "first")


class ExampleTests(unittest.TestCase):
    """Exercise source inventory and checked-excerpt failure cases."""

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        for path in ("src/larecs", "docs/src", "docs/test", "examples/particles"):
            (self.root / path).mkdir(parents=True)
        (self.root / "examples/particles/example.mojo").write_text('def main():\n    pass\n')
        (self.root / "docs/src/example.md").write_text('```mojo {doctest="one" global=true}\ndef main():\n    pass\n```\n')
        (self.root / "docs/test/example_one_test.mojo").write_text('def main():\n    pass\n')

    def doctest_results(self, *labels):
        """Build runner result sections for the independently authored fixtures."""
        return ''.join(f'=== {label} ===\ncompile: PASS exit=0\n'
                       'run: PASS exit=0\nresult: PASS\n' for label in labels)

    def test_missing_individual_and_all_doctests(self):
        with (self.root / "docs/src/example.md").open("a") as file:
            file.write('\n```mojo {doctest="two"}\nprint(2)\n```\n')
        labels = ['docs/src/example.md:1#one', 'docs/src/example.md:6#two']
        complete = self.doctest_results(*labels)
        self.assertEqual(coverage(complete, [], self.root)["doctests"], labels)
        # Keep the runner's successful summary even when evidence disappears.
        summary = 'Summary: total=2 passed=2 failed_compile=0 failed_run=0 skipped=0\n'
        for missing in ([labels[0]], [labels[1]], labels):
            with self.subTest(missing=missing):
                log = self.doctest_results(*(label for label in labels if label not in missing))
                with self.assertRaisesRegex(ValueError, "Doctest coverage differs: missing="):
                    coverage(log + summary, [], self.root)

    def test_incomplete_and_unsuccessful_doctest_results(self):
        label = 'docs/src/example.md:1#one'
        complete = self.doctest_results(label)
        for log in (f'=== {label} ===\n',
                    complete.replace('compile: PASS exit=0\n', ''),
                    complete.replace('run: PASS exit=0\n', ''),
                    complete.replace('result: PASS\n', ''),
                    complete.replace('run: PASS exit=0', 'run: FAIL exit=1')):
            with self.subTest(log=log), self.assertRaisesRegex(ValueError, "Incomplete or unsuccessful"):
                coverage(log, [], self.root)

    def test_duplicate_and_unexpected_doctest_results(self):
        complete = self.doctest_results('docs/src/example.md:1#one')
        with self.assertRaisesRegex(ValueError, "Duplicate doctest result"):
            coverage(complete + complete, [], self.root)
        with self.assertRaisesRegex(ValueError, "unexpected=.*unknown"):
            coverage(complete + self.doctest_results('docs/src/example.md:1#unknown'), [], self.root)

    def test_no_source_doctests_is_an_error(self):
        (self.root / "docs/src/example.md").write_text('No doctests.\n')
        with self.assertRaisesRegex(ValueError, "No source doctests"):
            coverage('', [], self.root)

    def test_source_labels_group_blocks_per_docstring(self):
        source = ('def first():\n    """First example.\n'
                  '    ```mojo {doctest="shared" global=true hide=true}\n'
                  '    from std.testing import assert_equal\n    ```\n'
                  '    ```mojo {doctest="shared"}\n    assert_equal(1, 1)\n    ```\n'
                  '    """\ndef second():\n    """Second example.\n'
                  '    ```mojo {doctest="shared"}\n    print(2)\n    ```\n    """\n')
        (self.root / "src/larecs/example.mojo").write_text(source)
        labels = {'docs/src/example.md:1#one',
                  'src/larecs/example.mojo:3#shared',
                  'src/larecs/example.mojo:12#shared'}
        self.assertEqual(source_doctests(self.root), labels)
        self.assertEqual(set(coverage(self.doctest_results(*labels), [], self.root)["doctests"]), labels)

    def test_inventory_ignores_prose_nested_fences_and_hidden_sources(self):
        with (self.root / "docs/src/example.md").open("a") as file:
            file.write('Use `doctest="prose"` in a fence.\n'
                       '````markdown\n```mojo {doctest="nested"}\nprint(1)\n```\n````\n')
        hidden = self.root / "src/larecs/.hidden"
        hidden.mkdir()
        (hidden / "example.mojo").write_text('```mojo {doctest="hidden"}\nprint(1)\n```\n')
        self.assertEqual(source_doctests(self.root), {'docs/src/example.md:1#one'})

    def test_source_inventory_accepts_tilde_fences_and_dotted_labels(self):
        with (self.root / "docs/src/example.md").open("a") as file:
            file.write('\n~~~mojo {doctest = "dotted.name"}\nprint(2)\n~~~\n')
        self.assertEqual(source_doctests(self.root), {
            'docs/src/example.md:1#one', 'docs/src/example.md:6#dotted.name',
        })

    def test_source_doctests_need_no_generated_files(self):
        (self.root / "docs/test/example_one_test.mojo").unlink()
        self.assertEqual(len(inventory(self.root)), 1)

    def test_prose_label_is_not_an_executable_listing(self):
        with (self.root / "docs/src/example.md").open("a") as file:
            file.write('Use `doctest="not_a_test"` for an inline example.\n')
        self.assertEqual(len(inventory(self.root)), 1)

    def test_stale_generated_files_are_not_executed(self):
        (self.root / "docs/test/stale.mojo").write_text('def main():\n    pass\n')
        self.assertEqual(len(inventory(self.root)), 1)
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
        doctests = self.doctest_results('docs/src/example.md:1#one')
        passed = coverage(prefix + 'PASS: actual device parity\n' + doctests, [program], self.root)
        skipped = coverage(prefix + 'SKIP: no accelerator\n' + doctests, [program], self.root)
        self.assertEqual(len(passed["actual_device_execution"]), 1)
        self.assertFalse(passed["hardware_skips"])
        self.assertEqual(passed["doctests"], ["docs/src/example.md:1#one"])
        self.assertFalse(skipped["actual_device_execution"])
        self.assertEqual(len(skipped["hardware_skips"]), 1)
        with self.assertRaisesRegex(ValueError, "Missing or ambiguous"):
            coverage(prefix + 'PASS\n' + doctests, [program], self.root)


class FigureTests(unittest.TestCase):
    """Keep Typst coverage strict alongside independently sourced site images."""

    def test_separate_images_do_not_hide_missing_or_unexpected_exports(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)
            sources = [output / 'figure.typ']
            for name in ('figure', 'aos_benchmark'):
                (output / f'{name}.svg').touch()
            check_inventory(sources, output)
            (output / 'figure.svg').unlink()
            with self.assertRaisesRegex(ValueError, 'Figure source/export inventory differs'):
                check_inventory(sources, output)
            (output / 'figure.svg').touch()
            (output / 'unexpected.svg').touch()
            with self.assertRaisesRegex(ValueError, 'Figure source/export inventory differs'):
                check_inventory(sources, output)


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

    def test_duplicate_anchors_are_detected(self):
        page = Page('<h2 id="same">Heading</h2><a id="same"></a>')
        self.assertEqual(page.duplicate_ids, {"same"})

    def test_region_indentation_matches_program(self):
        excerpt = regions('# region inner\n    a()\n    if True:\n        b()\n# endregion inner')['inner']
        self.assertEqual(excerpt, 'a()\nif True:\n    b()')



if __name__ == "__main__":
    unittest.main()
