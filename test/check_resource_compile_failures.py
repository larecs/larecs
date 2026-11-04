"""Run with `pixi run test-resource-compile-failures`.

Fixtures use .mojo.in so mogo-tester never discovers invalid Mojo programs.
Emit LLVM IR to test compilation without depending on the system linker.
Each fixture must compile with add replaced by set (which permits repeated
types), then fail with the specific add diagnostic in its original form.
"""

from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
DIAGNOSTIC = "ResourceStorage.add requires unique resource types"


class ResourceCompileFailures(unittest.TestCase):
    def test_duplicate_resource_packs(self):
        """Check every resource-add fixture and its positive compilation control."""
        fixtures = sorted((ROOT / "test/compile_fail").glob("resource_add_*.mojo.in"))
        self.assertTrue(fixtures, "No resource-add compile-failure fixtures found")
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "fixture.mojo"
            output = Path(directory) / "fixture.ll"
            for fixture in fixtures:
                for reject in (False, True):
                    with self.subTest(fixture=fixture.name, reject=reject):
                        code = fixture.read_text()
                        if not reject:
                            code = code.replace(
                                "resources.add(",
                                "resources.set[add_if_not_found=True](",
                            )
                        source.write_text(code)
                        result = subprocess.run(
                            [
                                "mojo", "build", "--emit", "llvm",
                                "-I", str(ROOT / "src"), str(source), "-o", str(output),
                            ],
                            capture_output=True,
                            text=True,
                            timeout=120,
                        )
                        if reject:
                            self.assertNotEqual(result.returncode, 0, result.stderr)
                            self.assertIn(DIAGNOSTIC, result.stderr)
                        else:
                            self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == "__main__":
    unittest.main()
