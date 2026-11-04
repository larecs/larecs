"""Run with `pixi run test-resource-compile-failures`.

Fixtures use .mojo.in so mogo-tester never discovers invalid Mojo programs.
Emit LLVM IR to test compilation without depending on the system linker.
Resource-add fixtures must compile with add replaced by set (which permits
repeated types), then fail with the specific add diagnostic in their original
form. Shared type-list fixtures also require a positive compilation control.
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

    def test_type_list_constraints(self):
        """Check shared constraints with a valid control for every rejection."""
        cases = [
            (
                "type_list_component_ids.mojo.in", {"@TYPES@": "Int, Float32"},
                "@TYPES@", "Int, Float32, Int",
                "Duplicate component types in get_id_arr are not allowed",
            ),
            (
                "type_list_component_ids.mojo.in", {"@TYPES@": "Int, Float32"},
                "@TYPES@", "Int, String", "Component type not in component manager",
            ),
            (
                "type_list_gpu.mojo.in",
                {"@PAYLOAD@": "Int32", "@FILTER@": "Filter().include[Value]()",
                 "@RESOURCES@": "Resources[]()",
                 "@CHECK@": "constrain_device_safe_components[Value]()",
                 "@DIAGNOSTIC@": "DeviceComponentType"},
                "@PAYLOAD@", "String", "DeviceComponentType",
            ),
            (
                "type_list_gpu.mojo.in",
                {"@PAYLOAD@": "Int32", "@FILTER@": "Filter().include[Int32]()",
                 "@RESOURCES@": "Resources[Value]()",
                 "@CHECK@": "constrain_device_safe_resources[Value]()",
                 "@DIAGNOSTIC@": "DeviceResourceType"},
                "@PAYLOAD@", "String", "DeviceResourceType",
            ),
        ]
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "fixture.mojo"
            output = Path(directory) / "fixture.ll"
            for fixture, replacements, key, invalid, diagnostic in cases:
                for reject in (False, True):
                    with self.subTest(
                        fixture=fixture, diagnostic=diagnostic, reject=reject,
                    ):
                        code = (ROOT / "test/compile_fail" / fixture).read_text()
                        for token, value in replacements.items():
                            replacement = invalid if reject and token == key else value
                            code = code.replace(token, replacement)
                        source.write_text(code)
                        result = subprocess.run(
                            ["mojo", "build", "--emit", "llvm", "-I",
                             str(ROOT / "src"), str(source), "-o", str(output)],
                            capture_output=True, text=True, timeout=120,
                        )
                        if reject:
                            self.assertNotEqual(result.returncode, 0, result.stderr)
                            self.assertIn(diagnostic, result.stderr)
                        else:
                            self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == "__main__":
    unittest.main()
