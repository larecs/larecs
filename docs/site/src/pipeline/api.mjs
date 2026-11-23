import { execFileSync } from 'node:child_process';
import { root, read, json, version, write } from './project.mjs';

export function sourceLocations(text) {
  const locations = new Map(), scopes = [];
  let inDocstring = false;
  text.split(/\r?\n/).forEach((line, index) => {
    if (line.includes('"""')) {
      if ((line.match(/"""/g) || []).length % 2) inDocstring = !inDocstring;
      return;
    }
    if (inDocstring) return;
    const match = line.match(/^( *)(?:def|struct|trait|comptime) (\w+)(?:\W|$)/);
    if (!match || ['if', 'for', 'assert'].includes(match[2])) return;
    const indent = match[1].length, name = match[2];
    while (scopes.length && scopes.at(-1).indent >= indent) scopes.pop();
    const key = [...scopes.map((scope) => scope.name), name].join('.');
    if (!locations.has(key)) locations.set(key, index + 1);
    scopes.push({ indent, name });
  });
  return locations;
}

export function rootExports(source) {
  // The initializer contains ordinary relative import statements, including
  // parenthesized lists; docstrings and comments cannot contribute exports.
  const imports = source.slice(source.indexOf('from .world import')).replace(/#[^\n]*/g, '');
  const exports = {};
  for (const match of imports.matchAll(/from\s+\.(\w+)\s+import\s+(\([^)]*\)|[^\n]+)/g)) {
    for (const entry of match[2].replace(/[()]/g, '').split(',')) {
      const [name, alias] = entry.trim().split(/\s+as\s+/);
      if (name) exports[alias || name] = `${match[1]}.${name}`;
    }
  }
  const manual = [...source.matchAll(/^ - ([\w.]+)$/gm)].map((match) => match[1]).sort();
  if (JSON.stringify(manual) !== JSON.stringify(Object.values(exports).sort())) throw new Error('Exports list differs from package imports');
  return exports;
}

export function buildReference(declaration = json('docs/src/larecs.json').decl) {
  const exports = rootExports(read('src/larecs/__init__.mojo'));
  const revision = execFileSync('git', ['rev-parse', 'HEAD'], { cwd: root, encoding: 'utf8' }).trim();
  const symbols = {}, locations = new Map();
  function add(name, target, source) {
    if (!locations.has(source)) locations.set(source, sourceLocations(read(source)));
    const owner = name.split('.').slice(1).map((part) => part.split('-')[0]);
    while (owner.length && !locations.get(source).has(owner.join('.'))) owner.pop();
    if (!owner.length) throw new Error(`No source declaration for ${name}`);
    const line = locations.get(source).get(owner.join('.'));
    symbols[name] = symbols[`larecs.${name}`] = {
      target, source, line, source_symbol: owner.at(-1),
      source_url: `https://github.com/larecs/larecs/blob/${revision}/${source}#L${line}`,
    };
  }
  for (const module of declaration.modules) {
    if (module.name === '__init__') continue;
    const source = `src/larecs/${module.name}.mojo`;
    for (const group of ['structs', 'traits', 'functions', 'aliases']) {
      for (const item of module[group] || []) {
        const target = group === 'aliases' ? `larecs/${module.name}/#${item.name}` : `larecs/${module.name}/${item.name}/`;
        const qualified = `${module.name}.${item.name}`;
        add(qualified, target, source);
        for (const memberGroup of ['functions', 'aliases']) for (const member of item[memberGroup] || []) {
          const anchor = memberGroup === 'aliases' ? member.name : member.name.toLowerCase();
          add(`${qualified}.${member.name}`, `${target}#${anchor}`, source);
          if (member.overloads?.length > 1) member.overloads.forEach((_, i) => add(`${qualified}.${member.name}-${i}`, `${target}#${member.name}-${i}`, source));
        }
      }
    }
  }
  const shortNames = new Map();
  for (const key of Object.keys(symbols).filter((key) => !key.startsWith('larecs.'))) {
    const short = key.slice(key.indexOf('.') + 1);
    shortNames.set(short, [...(shortNames.get(short) || []), key]);
  }
  for (const [short, candidates] of shortNames) if (candidates.length === 1) symbols[short] = symbols[candidates[0]];
  for (const [name, qualified] of Object.entries(exports)) {
    const key = `larecs.${qualified}`;
    if (!symbols[key]) throw new Error(`Root export missing from compiler JSON: ${qualified}`);
    for (const [symbol, metadata] of Object.entries(symbols)) if (symbol === key || symbol.startsWith(key + '.')) {
      const suffix = symbol.slice(key.length);
      symbols[name + suffix] = symbols[`larecs.${name}${suffix}`] = metadata;
    }
  }
  const legacy = { ...exports, ComponentManager: 'component.ComponentManager', DeviceComponentStorage: 'device_storage.DeviceComponentStorage', DeviceResourceStorage: 'device_storage.DeviceResourceStorage', EntityAccessor: 'entity.EntityAccessor', Replacer: 'host_storage.Replacer', BitPool: 'pool.BitPool' };
  const redirects = {}, case_redirects = {};
  for (const [name, qualified] of Object.entries(legacy)) {
    const target = symbols[`larecs.${qualified}`].target;
    if (target.includes('#')) continue;
    const route = `larecs/${name}/`;
    redirects[route] = target;
    if (declaration.modules.some((module) => module.name === name.toLowerCase())) case_redirects[route] = target;
  }
  const data = { revision, version, symbols, exports, redirects, case_redirects };
  write('docs/site/data/api.json', JSON.stringify(data, null, 2) + '\n');
  return data;
}
