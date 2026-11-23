import test from 'node:test';
import assert from 'node:assert/strict';
import { Documentation, regions, transformProse } from '../src/pipeline/content.mjs';
import { formatDeclaration, tokens } from '../src/pipeline/declaration-layout.mjs';
import { rootExports, sourceLocations } from '../src/pipeline/api.mjs';
import { json, read, base, deployment } from '../src/pipeline/project.mjs';

import { main } from '../run.mjs';

const declaration = json('docs/src/larecs.json').decl;
const docs = new Documentation(declaration);
const lexical = text => text.match(/"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|\w+|[^\s]/g) || [];
const decode = html => html.replace(/<[^>]*>/g, '').replace(/&#x([a-f0-9]+);|&#(\d+);/gi, (_, hex, dec) => String.fromCodePoint(parseInt(hex || dec, hex ? 16 : 10))).replaceAll('&lt;', '<').replaceAll('&gt;', '>').replaceAll('&quot;', '"').replaceAll('&amp;', '&');
function method(module, owner, name) {
  const m = declaration.modules.find(m => m.name === module);
  const type = [...m.structs, ...m.traits].find(type => type.name === owner);
  return type.functions.find(fn => fn.name === name).overloads[0];
}
function* signatures(node) {
  if (Array.isArray(node)) { for (const item of node) yield* signatures(item); }
  else if (node && typeof node === 'object') {
    if (node.signature) yield node.signature;
    for (const value of Object.values(node)) yield* signatures(value);
  }
}

test('declaration corpus preserves tokens, is idempotent, and meets the width target', () => {
  let checked = 0;
  for (const source of signatures(declaration)) {
    const formatted = formatDeclaration(source);
    assert.deepEqual(lexical(formatted), lexical(source), source);
    assert.equal(formatDeclaration(formatted), formatted, source);
    for (const line of formatted.split('\n')) {
      if (line.length <= 80) continue;
      const available = 80 - line.match(/^ */)[0].length;
      assert.ok(tokens(line).some(token => !/^\s+$/.test(token) && token.length > available), `Splittable overwidth line: ${line}`);
    }
    checked++;
  }
  assert.ok(checked > 400);
});
test('ResourceAccessor.get breaks conditional expressions at safe boundaries', () => {
  const source = method('system', 'ResourceAccessor', 'get').signature;
  const formatted = formatDeclaration(source);
  assert.ok(formatted.split('\n').every(line => line.length <= 80), formatted);
  assert.deepEqual(lexical(formatted), lexical(source));
  assert.equal(formatDeclaration(formatted), formatted);
});
test('indivisible literals retain their contents even beyond the target width', () => {
  const literal = '"' + 'x'.repeat(100) + '"';
  const source = `def literal[value: String = ${literal}](self)`;
  const formatted = formatDeclaration(source);
  assert.ok(formatted.includes(literal));
  const long = formatted.split('\n').filter(line => line.length > 80);
  assert.ok(long.length && long.every(line => tokens(line).includes(literal)));
  assert.equal(formatDeclaration(formatted), formatted);
});
test('long signatures put both lists on their own lines', () => {
  const source = 'def apply[T: ComponentType, U: ResourceType](mut self, source: T, value: U) -> Entity';
  assert.equal(formatDeclaration(source), 'def apply[\n    T: ComponentType,\n    U: ResourceType\n](\n    mut self,\n    source: T,\n    value: U\n) -> Entity');
  assert.equal(formatDeclaration('def get(self) -> Int'), 'def get(self) -> Int');
  const markers = formatDeclaration('def get[T: AnyType, //, name: String = "a, [b] (c)", *, mode: Int = 0](self, values: Tuple[T, T, T],) -> T');
  assert.ok(markers.includes('    //,\n') && markers.includes('    *,\n'));
  assert.ok(markers.includes('"a, [b] (c)"') && markers.includes('    values: Tuple[T, T, T],\n'));
});
test('real BitMaskFilter constructor links expanded public aliases without replacing compiler text', () => {
  const constructor = method('filter', 'BitMaskFilter', '__init__');
  for (const name of ['include', 'exclude']) {
    const argument = constructor.args.find(arg => arg.name === name);
    const rendered = docs.typeAnnotation(argument, 'filter.BitMaskFilter');
    assert.equal(decode(rendered), argument.type);
    assert.ok(rendered.includes(`href="${base}larecs/bitmask/#BitMask"`), rendered);
  }
  const rendered = docs.contract(constructor, 'filter.BitMaskFilter', 'fixture');
  assert.ok(rendered.includes('<strong class="api-name">include</strong> (<code') && rendered.includes('<strong class="api-name">exclude</strong> (<code'));
  assert.equal((rendered.match(/larecs\/bitmask\/#BitMask/g) || []).length, 2);
  assert.ok(rendered.includes(constructor.signature));
});
test('nested callable types, aliases, Self and references link only owned types', () => {
  const expression = 'def(List[larecs.entity.Entity], KernelContext[filter]) -> Optional[Entity]';
  const rendered = docs.typeAnnotation({ type: expression }, 'system.SystemContext');
  assert.equal(decode(rendered), expression);
  assert.ok(rendered.includes('larecs/entity/Entity/') && rendered.includes('larecs/system/KernelContext/'));
  assert.ok(!rendered.includes('>List</a>') && !rendered.includes('>Optional</a>'));
  assert.ok(docs.typeAnnotation({ type: 'ComponentType', path: '/larecs/component/#componenttype' }, 'world.World').includes('#ComponentType'));
  assert.ok(docs.typeAnnotation({ type: 'Self' }, 'world.World').includes('larecs/world/World/'));
  const reference = docs.typeAnnotation({ type: 'ref["Entity"] Entity', path: '/larecs/entity/Entity' }, 'world.World');
  assert.equal((reference.match(/<a /g) || []).length, 1);
  assert.equal(decode(reference), 'ref["Entity"] Entity');
});
test('owner-relative and labeled references retain their targets', () => {
  assert.equal(docs.link('.add_entity', 'host_storage.HostStorage'), docs.link('host_storage.HostStorage.add_entity'));
  assert.equal(docs.link('.BitPool.get', 'pool.BitPool'), docs.link('pool.BitPool.get'));
  docs.api.symbols['bitmask.BitMask.__str__'] = { target: 'larecs/bitmask/BitMask/#__str__' };
  assert.equal(docs.link('.__str__', 'bitmask.BitMask'), 'larecs/bitmask/BitMask/#__str__');
  const rendered = docs.prose('[..entity.Entity Entities] and [.HostStorage.is_locked locked]', 'host_storage.HostStorage');
  assert.ok(rendered.includes('[Entities](') && rendered.includes('[locked]('));
  assert.throws(() => docs.prose('[..entity.DoesNotExist Missing]', 'host_storage.HostStorage'), /Unknown API symbol/);
});
test('code remains literal while prose links are transformed', () => {
  const text = '```mojo\ndef get[T](self) -> Foo[T](self)\n```\n`f[T](x)` <code>x[T](y)</code> [link](target)';
  const rendered = transformProse(text, text => text.replaceAll('(target)', '(changed)'));
  assert.ok(rendered.includes('Foo[T](self)') && rendered.includes('`f[T](x)`') && rendered.includes('<code>x[T](y)</code>'));
  assert.ok(rendered.includes('[link](changed)'));
});
test('source ownership and exports reject drift', () => {
  const source = 'struct First:\n    """Example:\n    def method(): pass\n    """\n    def actual(self): pass\nstruct Second:\n    def method(self): pass\n';
  const locations = sourceLocations(source);
  assert.equal(locations.get('First.actual'), 5); assert.equal(locations.get('Second.method'), 7);
  assert.ok(!locations.has('First.method'));
  const init = read('src/larecs/__init__.mojo');
  assert.equal(rootExports(init).World, 'world.World');
  assert.throws(() => rootExports(init.replace(' - world.World\n', '')), /Exports list differs/);
});
test('missing examples, regions, symbols and documentation fail closed', () => {
  for (const text of ['{{< api DoesNotExist >}}', '{{< example file="missing.mojo" >}}', '{{< example file="particles/movement.mojo" region="missing" >}}']) assert.throws(() => docs.shortcodes(text));
  assert.throws(() => docs.contract({ kind: 'struct', name: 'Undocumented' }, 'example', 'fixture'), /Missing declaration documentation/);
  assert.equal(regions('# region inner\n    a()\n    if True:\n        b()\n# endregion inner').inner, 'a()\nif True:\n    b()');
  for (const source of ['# region a\npass', '# endregion a', '# region a\n# endregion a']) assert.throws(() => regions(source));
});

test('fresh preview installs locked Node dependencies before Astro starts', async () => {
  for (const command of ['serve', 'watch']) {
    const calls = [];
    await main(command, async (...args) => calls.push(args));
    assert.equal(calls[0][0], 'npm'); assert.deepEqual(calls[0][1], ['ci']);
    assert.deepEqual(calls[1][1].slice(1), ['dev', '--host', '127.0.0.1']);
  }
});

test('real contracts show linked parameter, argument and result types', () => {
  const added = docs.contract(method('host_storage', 'HostStorage', 'add_entity'), 'host_storage.HostStorage', 'fixture');
  assert.ok(added.includes('larecs/component/#ComponentType'));
  assert.ok(added.includes('<p class="api-label">Returns:</p>\n\n- <code class="api-type"><a href="' + base + 'larecs/entity/Entity/">Entity</a></code>'));
  const world = docs.contract(method('world', 'World', '__init__'), 'world.World', 'fixture');
  assert.ok(world.includes('<strong class="api-name">execution_config</strong> (<code class="api-type"><a href="' + base + 'larecs/execution/ThreadedExecutionConfig/">'));
});

test('type pages group members under section headings', () => {
  docs.apiPages();
  const world = docs.pages.get('larecs/world/World').body;
  const order = ['## Parameters', '## Fields', '## Implemented traits', '## Methods', '### `__init__`'].map((heading) => world.indexOf(heading));
  assert.ok(order.every((index, i) => index >= 0 && (i === 0 || index > order[i - 1])), order.join());
  assert.ok(world.startsWith('\n<p class="api-source lg:sl-hidden">'));
  assert.ok(!world.includes('<strong class="api-name">self</strong> (<code class="api-type"><a href="' + base + 'larecs/world/World/">Self'));
  assert.equal(docs.pages.get('larecs/world/World').data.source, docs.api.symbols['world.World'].source_url);
  assert.throws(() => docs.sectionSafe('Methods', ['Methods'], 'fixture'), /collides with a section heading/);
});
test('deployment prefixes identify their version and shared root', () => {
  assert.deepEqual(deployment('https://example.test/larecs/v1.2.0rc1/', '9.9.9'), { kind: 'Release', root: '/larecs/', version: '1.2.0rc1', label: 'v1.2.0rc1' });
  assert.deepEqual(deployment('https://example.test/larecs/dev/', '9.9.9'), { kind: 'Development', root: '/larecs/', version: '9.9.9', label: 'Development · 9.9.9' });
  assert.deepEqual(deployment('https://example.test/deploy/pr-preview/pr-999/', '9.9.9'), { kind: 'Preview', root: '/deploy/', version: '9.9.9', label: 'PR #999 preview' });
});
test('legacy guide fragments survive Astro rendering', () => {
  assert.equal(docs.shortcodes('{{< legacy-anchor "old-section" >}}'), '<a id="old-section"></a>');
});
