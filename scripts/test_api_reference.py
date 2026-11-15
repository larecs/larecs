"""Integration checks for the compiler/Starlight reference build.

Run after `pixi run build-docs` with the scripts Pixi test-api-reference task.
"""

import json
import os
import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

from api_reference import ROOT, root_exports
from check_api_reference import Page, check
from check_docs import check as check_site, Page as SitePage
from docs_redirects import write_case_redirects
from check_docs_browser import check_browser
from render_docs import BASE, Renderer
from declaration_layout import format_declaration


class DeclarationLayoutTests(unittest.TestCase):
    """Check source-preserving layout across real compiler declarations."""

    def test_short_declaration_stays_inline(self):
        declaration = 'def get(self) -> Int'
        self.assertEqual(format_declaration(declaration), declaration)

    def test_long_parameter_and_argument_lists(self):
        declaration = 'def apply[T: ComponentType, U: ResourceType](mut self, source: T, value: U) -> Entity'
        formatted = format_declaration(declaration)
        self.assertEqual(formatted, '''def apply[
    T: ComponentType,
    U: ResourceType
](
    mut self,
    source: T,
    value: U
) -> Entity''')

    def test_nested_callable_accounts_for_suffix(self):
        declaration = 'def run[KernelFunc: def(KernelContext[filter, required_resources, capture_spec]) thin -> None](mut self)'
        formatted = format_declaration(declaration)
        self.assertIn('KernelFunc: def(\n', formatted)
        self.assertTrue(all(len(line) <= 80 for line in formatted.splitlines()))

    def test_literals_and_inference_markers(self):
        declaration = 'def get[T: AnyType, //, name: String = "a, [b] (c)", *, mode: Int = 0](self, values: Tuple[T, T, T],) -> T'
        formatted = format_declaration(declaration)
        self.assertIn('    //,\n', formatted)
        self.assertIn('"a, [b] (c)"', formatted)
        self.assertIn('    *,\n', formatted)
        self.assertIn('    values: Tuple[T, T, T],\n', formatted)
        self.assertEqual(format_declaration(formatted), formatted)

    def test_all_compiler_declarations_preserve_tokens(self):
        # Compare lexical tokens independently of the formatter's scanner.
        def tokens(text):
            return re.findall(r""""(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|\w+|[^\s]""", text)

        def walk(node):
            if isinstance(node, dict):
                if node.get('signature'):
                    signature = node['signature']
                    formatted = format_declaration(signature)
                    with self.subTest(signature=signature[:100]):
                        self.assertEqual(tokens(signature), tokens(formatted))
                        self.assertEqual(format_declaration(formatted), formatted)
                for child in node.values():
                    walk(child)
            elif isinstance(node, list):
                for child in node:
                    walk(child)

        walk(json.loads((ROOT / 'docs/src/larecs.json').read_text())['decl'])


class TypeAnnotationTests(unittest.TestCase):
    """Keep compiler type expressions intact while linking their owned types."""

    @classmethod
    def setUpClass(cls):
        cls.renderer = Renderer()

    def test_nested_callable_and_qualified_types(self):
        expression = 'def(List[larecs.entity.Entity], KernelContext[filter]) -> Optional[Entity]'
        rendered = self.renderer.type_annotation({'type': expression}, 'system.SystemContext')
        self.assertEqual(''.join(SitePage(rendered).text), expression)
        self.assertEqual(Page(rendered).links, [
            BASE + 'larecs/entity/Entity/', BASE + 'larecs/system/KernelContext/',
            BASE + 'larecs/entity/Entity/',
        ])

    def test_alias_paths_and_self(self):
        rendered = self.renderer.type_annotation({
            'type': 'ComponentType', 'path': '/larecs/component/#componenttype',
        }, 'world.World')
        self.assertEqual(Page(rendered).links, [BASE + 'larecs/component/#ComponentType'])
        rendered = self.renderer.type_annotation({'type': 'Self'}, 'world.World')
        self.assertEqual(Page(rendered).links, [BASE + 'larecs/world/World/'])

    def test_reference_qualifier_and_literals_are_not_type_links(self):
        expression = 'ref["Entity"] Entity'
        rendered = self.renderer.type_annotation({
            'type': expression, 'path': '/larecs/entity/Entity',
        }, 'world.World')
        self.assertEqual(''.join(SitePage(rendered).text), expression)
        self.assertEqual(Page(rendered).links, [BASE + 'larecs/entity/Entity/'])

    def test_contract_links_arguments_parameters_and_returns(self):
        declaration = json.loads((ROOT / 'docs/src/larecs.json').read_text())['decl']
        module = next(m for m in declaration['modules'] if m['name'] == 'host_storage')
        storage = next(s for s in module['structs'] if s['name'] == 'HostStorage')
        add_entity = next(f for f in storage['functions'] if f['name'] == 'add_entity')['overloads'][0]
        contract = self.renderer.contract(add_entity, 'host_storage.HostStorage', Path('fixture'))
        self.assertIn(BASE + 'larecs/component/#ComponentType', contract)
        self.assertIn('**Returns**\n\n<code class="api-type"><a href="' + BASE + 'larecs/entity/Entity/">Entity</a></code>', contract)
        module = next(m for m in declaration['modules'] if m['name'] == 'world')
        world = next(s for s in module['structs'] if s['name'] == 'World')
        initializer = next(f for f in world['functions'] if f['name'] == '__init__')['overloads'][0]
        contract = self.renderer.contract(initializer, 'world.World', Path('fixture'))
        self.assertIn('`execution_config`: <code class="api-type"><a href="' + BASE + 'larecs/execution/ThreadedExecutionConfig/">', contract)


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
            (root / "docs/site/public/example").mkdir(parents=True)
            (root / "docs/site/public/example/index.html").write_text('<h1 id="present">Example</h1>')
            (root / "docs/site/data/api.json").write_text(json.dumps({"symbols": {"Example": {"target": "example/#missing"}}}))
            with self.assertRaisesRegex(ValueError, "Missing API anchor"):
                check(root)

    def test_preview_base_path(self):
        base = "https://example.test/deploy/pr-preview/pr-999/"
        command = [sys.executable, "-c", "import sys; sys.path.insert(0, 'scripts'); from docs import generate, site; site(generate())"]
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
