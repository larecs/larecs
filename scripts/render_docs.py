"""Generate Starlight pages and executable doctests directly from source."""
import json
import os
import re
import shlex
import shutil
import tomllib
from pathlib import Path
from urllib.parse import urljoin, urlsplit

from api_reference import ROOT, build_reference
from doc_examples import regions

BASE = os.environ.get('DOCS_BASE_URL', 'https://larecs.github.io/larecs/dev/')
CONTENT = ROOT / 'docs/site/src/content/docs'
TESTS = ROOT / 'docs/test'


def fence(code):
    return '\n```mojo-render\n' + code.strip() + '\n```\n'


class Renderer:
    def __init__(self):
        self.api = build_reference()
        self.tests = {}
        self.redirects = dict(self.api['redirects'])

    def link(self, symbol, context=''):
        symbol = symbol.removeprefix('larecs.')
        if symbol.startswith('.'):
            dots = len(symbol) - len(symbol.lstrip('.'))
            parts = context.split('.')[:1]
            symbol = '.'.join(parts[:len(parts)-dots+1] + [symbol[dots:]])
        candidates = [symbol, context + '.' + symbol]
        for candidate in candidates:
            if candidate in self.api['symbols']:
                return self.api['symbols'][candidate]['target']
        raise ValueError(f'Unknown API symbol {symbol} in {context}')

    def prose(self, text, context=''):
        # Compiler docstrings use Modo-style [relative.Symbol] references.
        def cross(match):
            symbol = match[1]
            return f'[{symbol.lstrip(".")}]({BASE}{self.link(symbol, context)})'
        text = re.sub(r'(?<![!`\w])\[([.\w]+)\](?![(`\[])', cross, text)
        return text

    def extract(self, text, owner):
        def block(match):
            attrs, code = match[1], match[2]
            label = re.search(r'doctest="([\w-]+)"', attrs)
            if not label:
                raise ValueError(f'Unchecked Mojo listing: {owner}')
            key = owner.parent / f'{owner.name}_{label[1]}_test.mojo'
            self.tests.setdefault(key, []).append(('global=true' in attrs, code))
            return '' if 'hide=true' in attrs else fence(code)
        return re.sub(r'```mojo(?=[ \n])([^\n]*)\n(.*?)\n```', block, text, flags=re.S)

    def shortcodes(self, text):
        def shortcode(match):
            if match[1].startswith('/*'):
                return match[0].replace('/*', '').replace('*/', '')
            args = shlex.split(match[1]); kind = args.pop(0)
            if kind == 'api':
                return f'[{args[1] if len(args)>1 else args[0]}]({BASE}{self.link(args[0])})'
            if kind == 'source':
                return f'[Source](https://github.com/larecs/larecs/blob/{self.api["revision"]}/src/larecs/{args[0]})'
            if kind == 'repo':
                return f'[{args[1] if len(args)>1 else args[0]}](https://github.com/larecs/larecs/blob/{self.api["revision"]}/{args[0]})'
            if kind == 'api-status':
                return f'Development reference · Larecs {self.api["version"]} · revision `{self.api["revision"][:12]}`. [Compatibility and status]({BASE}reference/compatibility/).'
            if kind == 'example':
                attrs = dict(arg.split('=', 1) for arg in args)
                path = (ROOT / 'examples' / attrs['file']).resolve()
                if not path.is_relative_to(ROOT / 'examples') or not path.is_file():
                    raise ValueError(f'Missing example: {path}')
                code = path.read_text()
                if 'region' in attrs:
                    return fence(regions(code)[attrs['region']])
                url = f'https://github.com/larecs/larecs/blob/{self.api["revision"]}/examples/{attrs["file"]}'
                return '<details><summary>Complete runnable program</summary>\n\n' + f'[Source: `{attrs["file"]}`]({url})\n' + fence(re.sub(r'(?m)^\s*# (?:end)?region .*\n', '', code)) + '\n</details>\n'
            raise ValueError(f'Unknown shortcode: {kind}')
        return re.sub(r'{{<\s*(.*?)\s*>}}', shortcode, text)

    def write(self, route, title, body, weight=0, hidden=False):
        # Resolve authored links using the existing trailing-slash routes.
        def destination(match):
            url = match[1]
            if url.startswith(('http:', 'https:', '#', 'mailto:')):
                return match[0]
            resolved = urlsplit(urljoin(BASE if url.startswith('/') else BASE + route + '/', url.lstrip('/') if url.startswith('/') else url))
            path = resolved.path
            if not Path(path).suffix and not path.endswith('/'):
                path += '/'
            return '](' + resolved._replace(path=path).geturl() + ')'
        body = re.sub(r'\]\(([^\s)]+)\)', destination, body)
        path = CONTENT / (route + '.md' if route else 'index.md')
        path.parent.mkdir(parents=True, exist_ok=True)
        metadata = {'title': title, 'slug': route, 'sidebar': {'order': weight, 'hidden': hidden}}
        body = body.replace('```mojo-render', '```mojo')
        path.write_text('---\n' + '\n'.join(f'{key}: {json.dumps(value)}' for key, value in metadata.items()) + '\n---\n\n' + body + '\n')

    def authored(self):
        for path in sorted((ROOT / 'docs/src').rglob('*.md')):
            raw = path.read_text()
            _, head, body = raw.split('+++', 2)
            data = tomllib.loads(head)
            relative = path.relative_to(ROOT / 'docs/src').with_suffix('')
            route = str(relative).removesuffix('_index').rstrip('/')
            body = self.shortcodes(self.extract(body, relative))
            if data.get('draft'):
                continue
            for alias in data.get('aliases', []):
                self.redirects[alias.strip('/') + '/'] = route + '/'
            self.write(route, data['title'], body, data.get('weight', 0), hidden=data.get('sidebar', {}).get('exclude', False))

    def contract(self, item, context, owner):
        if item.get('kind') in {'module', 'struct', 'trait', 'alias', 'function'} and not item.get('summary') and not item.get('overloads'):
            raise ValueError(f'Missing declaration documentation: {context}.{item.get("name")}')
        text = item.get('summary', '') + '\n\n'
        exact = item.get('signature', '')
        if item.get('kind') == 'alias' and item.get('value') != 'fn_literal':
            exact += (': ' + item['type'] if item.get('type') else '') + ' = ' + item.get('value', '')
        if exact:
            readable = re.sub(r'\s+where \(eq .*$', '', exact)
            readable = re.sub(r': (\w+)\[[a-z_]\w*\.\w+[^\[\]]*\]', r': \1', readable)
            text += fence(readable)
            if exact != readable:
                text += '\n<details><summary>Exact declaration</summary>\n' + fence(exact) + '\n</details>\n'
        text += '\n' + item.get('description', '') + '\n'
        if item.get('parentTraits'):
            text += '\n**Traits**\n\n' + ', '.join('`' + trait['name'] + '`' for trait in item['parentTraits']) + '\n'
        for key, label in [('parameters', 'Parameters'), ('args', 'Arguments'), ('fields', 'Fields')]:
            values = item.get(key, [])
            if values:
                text += '\n**' + label + '**\n\n'
                for value in values:
                    text += '- `' + value['name'] + '`'
                    if value.get('type'):
                        text += ': `' + value['type'] + '`'
                    text += ' — ' + value.get('description', '') + '\n'
        for key, label in [('returns', 'Returns'), ('raisesDoc', 'Raises'), ('constraints', 'Constraints')]:
            value = item.get(key)
            if isinstance(value, dict):
                value = value.get('doc', '')
            if value:
                text += f'\n**{label}**\n\n{value}\n'
        # Cross references are prose only, never declarations or executable code.
        text = self.extract(text, owner)
        pieces = re.split(r'(```.*?```|`[^`\n]+`)', text, flags=re.S)
        return ''.join(part if part.startswith('`') else self.prose(part, context) for part in pieces)

    def api_pages(self):
        decl = json.loads((ROOT / 'docs/src/larecs.json').read_text())['decl']
        root_links = []
        for module in decl['modules']:
            name = module['name']
            if name == '__init__':
                continue
            if not module.get('summary'):
                raise ValueError(f'Missing module documentation: {name}')
            route = 'larecs/' + name
            owner = Path('larecs') / ('larecs_' + name)
            body = self.contract(module, name, owner)
            for group in ['aliases', 'structs', 'traits', 'functions']:
                for item in module.get(group, []):
                    if not item.get('summary') and not item.get('overloads'):
                        raise ValueError(f'Missing declaration documentation: {name}.{item["name"]}')
                    symbol = name + '.' + item['name']
                    if group == 'aliases':
                        body += (f'\n<a id="{item["name"]}"></a>\n' if item['name'] != item['name'].lower() else '') + f'\n## `{item["name"]}`\n' + self.contract(item, name, owner)
                        continue
                    target = self.api['symbols'][symbol]['target']
                    body += f'\n- [{item["name"]}]({BASE}{target})\n'
                    item_owner = Path('larecs') / ('larecs_' + name + '_' + item['name'])
                    details = f'[Source]({self.api["symbols"][symbol]["source_url"]})\n\n'
                    details += self.contract(item, symbol, item_owner)
                    for alias in item.get('aliases', []):
                        details += (f'\n<a id="{alias["name"]}"></a>\n' if alias['name'] != alias['name'].lower() else '') + f'\n## `{alias["name"]}`\n' + self.contract(alias, symbol, item_owner)
                    for member in item.get('functions', []):
                        member_source = self.api['symbols'][symbol + '.' + member['name']]['source_url']
                        details += f'\n## `{member["name"]}`\n\n[Source]({member_source})\n'
                        for i, overload in enumerate(member.get('overloads', [member])):
                            details += f'\n<a id="{member["name"]}-{i}"></a>\n\n' + self.contract(overload, symbol, item_owner)
                    for overload in item.get('overloads', []):
                        details += self.contract(overload, name, item_owner)
                    self.write(target.strip('/'), item['name'], details)
            self.write(route, name, body)
            root_links.append(f'- [{name}]({BASE}{route}/)')
        exports = '\n'.join(f'- [`{name}`]({BASE}{self.api["symbols"][name]["target"]})' for name in self.api['exports'])
        self.write('larecs', 'API docs', '## Root exports\n\n' + exports + '\n\n## Modules\n\n' + '\n'.join(root_links))

    def generate(self):
        shutil.rmtree(CONTENT, ignore_errors=True)
        shutil.rmtree(TESTS, ignore_errors=True)
        self.authored()
        self.write("404", "Page not found", "The requested page does not exist. Use the navigation or search to find it.", hidden=True)
        self.api_pages()
        for path, blocks in self.tests.items():
            global_code = '\n'.join(code for is_global, code in blocks if is_global)
            local_code = '\n'.join(code for is_global, code in blocks if not is_global)
            if local_code:
                global_code += '\n\ndef main() raises:\n' + '\n'.join('    ' + line for line in local_code.splitlines())
            target = TESTS / path
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(global_code + '\n')
        (ROOT / 'docs/site/data/redirects.json').write_text(json.dumps(self.redirects, indent=2) + '\n')


if __name__ == '__main__':
    Renderer().generate()
