import { existsSync, realpathSync, rmSync } from 'node:fs';
import { resolve, relative, extname } from 'node:path';
import { parse } from 'smol-toml';
import { root, base, read, json, write, files, escapeHtml } from './project.mjs';
import { buildReference } from './api.mjs';
import { formatDeclaration } from './declaration-layout.mjs';

// Maintainer pages kept under docs/src for history reasons; they are not published.
const REPOSITORY_ONLY = new Set(['guide/development_workflow']);
const fence = (code) => '\n```mojo-render\n' + code.trim() + '\n```\n';
const declaration = (code) => '\n<div class="api-declaration">\n' + fence(code) + '\n</div>\n';
const codeText = (text) => escapeHtml(text).replace(/[\\`*_\[\]()]/g, (char) => `&#${char.charCodeAt(0)};`);
export function transformProse(text, transform) {
  return text.split(/(^```[^\n]*\n[\s\S]*?^```[^\n]*$|`[^`\n]+`|<code\b[^>]*>[\s\S]*?<\/code>)/m)
    .map((part) => part.startsWith('`') || part.startsWith('<code') ? part : transform(part)).join('');
}
export function regions(source) {
  const result = {}, active = [], lines = source.split(/\r?\n/);
  lines.forEach((line, index) => {
    const marker = line.match(/^\s*# (end)?region ([\w-]+)\s*$/);
    if (!marker) return;
    const [, end, name] = marker;
    if (end) {
      if (active.at(-1)?.name !== name) throw new Error(`Unbalanced example region: ${name}`);
      const start = active.pop().start, excerpt = lines.slice(start, index);
      const indent = Math.min(...excerpt.filter((line) => line.trim()).map((line) => line.match(/^\s*/)[0].length));
      result[name] = excerpt.map((line) => line.slice(indent)).join('\n').trim();
      if (!result[name]) throw new Error(`Empty example region: ${name}`);
    } else {
      if (Object.hasOwn(result, name) || active.some((entry) => entry.name === name)) throw new Error(`Duplicate example region: ${name}`);
      active.push({ name, start: index + 1 });
    }
  });
  if (active.length) throw new Error(`Unclosed example region: ${active.at(-1).name}`);
  return result;
}
const words = (text) => (text.match(/(?:[^\s"']+|"[^"]*"|'[^']*')+/g) || []).map((word) => word.replace(/(["'])(.*?)\1/g, '$2'));

export class Documentation {
  constructor(decl = json('docs/src/larecs.json').decl) {
    this.decl = decl;
    this.api = buildReference(decl);
    this.pages = new Map();
    this.redirects = { ...this.api.redirects };
    this.typeTargets = new Map(); this.compilerTypes = new Map(); this.expandedAliases = new Map();
    for (const module of decl.modules) {
      if (module.name === '__init__') continue;
      for (const group of ['structs', 'traits', 'aliases']) for (const item of module[group] || []) {
        const name = `${module.name}.${item.name}`;
        this.registerType(name);
        for (const alias of item.aliases || []) this.registerType(`${name}.${alias.name}`);
        // The compiler expands some public aliases into private representations.
        // Index complete expressions so nested occurrences retain their text.
        if (group === 'aliases' && /^[A-Z]/.test(item.name) && /^\w+(?:\.\w+)*\[[\s\S]+\]$/.test(item.value || '')) {
          const key = item.value.replace(/\s/g, '');
          const previous = this.expandedAliases.get(key);
          this.expandedAliases.set(key, previous === undefined ? this.api.symbols[name].target : null);
        }
      }
    }
  }
  registerType(name) {
    const target = this.api.symbols[name].target;
    this.typeTargets.set(name, target);
    this.compilerTypes.set('/' + target.replace(/\/$/, '').toLowerCase(), target);
    for (const short of [name.slice(name.indexOf('.') + 1), name.split('.').at(-1)]) {
      if (this.api.symbols[short]?.target === target) this.typeTargets.set(short, target);
    }
  }
  typeAnnotation(value, context) {
    const expression = value.type, compilerPath = (value.path || '').replace(/\/$/, '').toLowerCase();
    const compilerTarget = this.compilerTypes.get(compilerPath), compilerName = compilerPath.split('/').at(-1).replace(/^#/, '');
    const link = (text, target) => `<a href="${escapeHtml(base + target)}">${codeText(text)}</a>`;
    let output = '', end = 0;
    const pattern = /"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|\b[A-Za-z_]\w*(?:\.[A-Za-z_]\w*)*/g;
    for (const match of expression.matchAll(pattern)) {
      if (match.index < end) continue;
      const name = match[0];
      output += codeText(expression.slice(end, match.index));
      let expansionEnd = match.index + name.length;
      if (!/^["']/.test(name) && expression[expansionEnd] === '[') {
        let depth = 0;
        for (let index = expansionEnd; index < expression.length; index++) {
          if (expression[index] === '[') depth++;
          if (expression[index] === ']' && --depth === 0) { expansionEnd = index + 1; break; }
        }
        const expanded = expression.slice(match.index, expansionEnd);
        const target = this.expandedAliases.get(expanded.replace(/\s/g, ''));
        if (target) { output += link(expanded, target); end = expansionEnd; continue; }
      }
      const local = /^Self(?:\.|$)/.test(name) ? context + name.slice(4) : `${context}.${name}`;
      const candidates = [local, `${context.split('.')[0]}.${name}`, name.replace(/^larecs\./, '')];
      let target = candidates.map((key) => this.typeTargets.get(key)).find(Boolean);
      if (compilerTarget && name.split('.').at(-1).toLowerCase() === compilerName) target = compilerTarget;
      output += !/^["']/.test(name) && target ? link(name, target) : codeText(name);
      end = match.index + name.length;
    }
    return '<code class="api-type">' + output + codeText(expression.slice(end)) + '</code>';
  }
  link(symbol, context = '') {
    symbol = symbol.replace(/^larecs\./, '');
    if (symbol.startsWith('.')) {
      const dots = symbol.match(/^\.+/)[0].length, parts = context.split('.').slice(0, 1);
      if (dots === 1 && this.api.symbols[context + symbol]) return this.api.symbols[context + symbol].target;
      symbol = [...parts.slice(0, Math.max(0, parts.length - dots + 1)), symbol.slice(dots)].join('.');
    }
    for (const candidate of [symbol, `${context}.${symbol}`]) if (this.api.symbols[candidate]) return this.api.symbols[candidate].target;
    throw new Error(`Unknown API symbol ${symbol} in ${context}`);
  }
  prose(text, context = '') {
    return text.replace(/(?<![!`\w])\[([.\w]+)(?:[ \t]+([^\]\n]+))?\](?![(`\[])/g, (_, symbol, label) => `[${label || symbol.replace(/^\.+/, '')}](${base}${this.link(symbol, context)})`);
  }
  extract(text, owner) {
    return text.replace(/^```mojo(?=[ \n])([^\n]*)\n([\s\S]*?)\n^```/gm, (_, attrs, code) => {
      const label = attrs.match(/doctest="([\w-]+)"/);
      if (!label) throw new Error(`Unchecked Mojo listing: ${owner}`);
      return attrs.includes('hide=true') ? '' : fence(code);
    });
  }
  shortcodes(text) {
    return text.replace(/{{<\s*(.*?)\s*>}}/g, (whole, content) => {
      if (content.startsWith('/*')) return whole.replace('/*', '').replace('*/', '');
      const [kind, ...args] = words(content);
      if (kind === 'legacy-anchor') return `<a id="${escapeHtml(args[0])}"></a>`;
      if (kind === 'api') return `[${args[1] || args[0]}](${base}${this.link(args[0])})`;
      if (kind === 'source') return `[Source](https://github.com/larecs/larecs/blob/${this.api.revision}/src/larecs/${args[0]})`;
      if (kind === 'repo') return `[${args[1] || args[0]}](https://github.com/larecs/larecs/blob/${this.api.revision}/${args[0]})`;
      if (kind === 'api-status') return `Development reference · Larecs ${this.api.version} · revision \`${this.api.revision.slice(0, 12)}\`. Threaded and device execution are experimental.`;
      if (kind !== 'example') throw new Error(`Unknown shortcode: ${kind}`);
      const attrs = Object.fromEntries(args.map((arg) => { const at = arg.indexOf('='); return [arg.slice(0, at), arg.slice(at + 1)]; }));
      const path = resolve(root, 'examples', attrs.file);
      if (!existsSync(path) || !realpathSync(path).startsWith(realpathSync(resolve(root, 'examples')) + '/')) throw new Error(`Missing example: ${attrs.file}`);
      const source = read(path);
      if (attrs.region) {
        const excerpt = regions(source)[attrs.region];
        if (excerpt === undefined) throw new Error(`Missing example region: ${attrs.file}:${attrs.region}`);
        return fence(excerpt);
      }
      const url = `https://github.com/larecs/larecs/blob/${this.api.revision}/examples/${attrs.file}`;
      return '<details><summary>Complete runnable program</summary>\n\n' + `[Source: \`${attrs.file}\`](${url})\n` + fence(source.replace(/^\s*# (?:end)?region .*\n/gm, '')) + '\n</details>\n';
    });
  }
  page(route, title, body, weight = 0, hidden = false, filePath, source) {
    body = transformProse(body, (prose) => prose.replace(/\]\(([^\s)]+)\)/g, (whole, href) => {
      if (/^(?:https?:|#|mailto:)/.test(href)) return whole;
      const url = new URL(href.replace(/^\//, ''), href.startsWith('/') ? base : base + (route ? route + '/' : ''));
      if (!extname(url.pathname) && !url.pathname.endsWith('/')) url.pathname += '/';
      return `](${url.href})`;
    }));
    body = transformProse(body, prose => prose.replace(/!\[[^\]]*\]\([^\s)]+\.svg\)/g, image => '\n<div class="diagram">\n\n' + image + '\n\n</div>\n')).replaceAll('```mojo-render', '```mojo');
    const id = route || 'index';
    this.pages.set(id, { id, body, filePath: filePath || resolve(root, `docs/site/src/content/docs/${id}.md`), data: { title, slug: route, sidebar: { order: weight, hidden }, ...(source ? { source } : {}) } });
  }
  authored() {
    for (const path of files('docs/src', '.md')) {
      const owner = relative(resolve(root, 'docs/src'), path).replace(/\.md$/, '');
      if (REPOSITORY_ONLY.has(owner)) continue;
      const [, head, ...bodyParts] = read(path).split('+++');
      const data = parse(head);
      const route = owner.replace(/_index$/, '').replace(/\/$/, '');
      const body = this.shortcodes(this.extract(bodyParts.join('+++'), owner));
      if (data.draft) continue;
      for (const alias of data.aliases || []) this.redirects[alias.replace(/^\/|\/$/g, '') + '/'] = route + '/';
      this.page(route, data.title, body, data.weight || 0, data.sidebar?.exclude || false, path);
    }
  }
  declaration(item) {
    let exact = item.signature || '';
    if (item.kind === 'alias' && item.value !== 'fn_literal') exact += (item.type ? ': ' + item.type : '') + ' = ' + (item.value || '');
    if (!exact) return '';
    const readable = exact.replace(/\s+where \(eq .*$/, '').replace(/: (\w+)\[[a-z_]\w*\.\w+[^\[\]]*\]/g, ': $1');
    const formatted = formatDeclaration(readable);
    let text = declaration(formatted);
    if (exact !== formatted) text += '\n<details class="api-exact"><summary>Exact declaration</summary>\n' + declaration(exact) + '\n</details>\n';
    return text;
  }
  values(values, context) {
    return values.map((value) => '- <strong class="api-name">' + escapeHtml(value.name) + '</strong>'
      + (value.type ? ' (' + this.typeAnnotation(value, context) + ')' : '')
      + (value.description ? ': ' + value.description : '') + '\n').join('');
  }
  traits(item) {
    return '<p class="api-traits">' + item.parentTraits.map((trait) => '<code>' + escapeHtml(trait.name) + '</code>').join(' ') + '</p>\n';
  }
  /** Declaration box, prose, and labelled argument lists for one declaration. */
  contract(item, context, owner, { sections = false } = {}) {
    if (['module', 'struct', 'trait', 'alias', 'function'].includes(item.kind) && !item.summary && !item.overloads) throw new Error(`Missing declaration documentation: ${context}.${item.name}`);
    const label = (name) => sections ? `\n## ${name}\n\n` : `\n<p class="api-label">${name}:</p>\n\n`;
    let text = this.declaration(item) + '\n' + (item.summary || '') + '\n\n' + (item.description || '') + '\n';
    for (const [key, name] of [['parameters', 'Parameters'], ['fields', 'Fields'], ['args', 'Args']]) {
      // The receiver and undocumented results are already visible in the declaration.
      const values = (item[key] || []).filter((value) => key !== 'args' || value.name !== 'self' || value.description);
      if (values.length) text += label(name) + this.values(values, context);
    }
    if (sections && item.parentTraits?.length) text += label('Implemented traits') + this.traits(item);
    for (const [key, name] of [['returns', 'Returns'], ['raisesDoc', 'Raises'], ['constraints', 'Constraints']]) {
      let value = item[key];
      if (value && typeof value === 'object' && key === 'returns' && !value.doc) continue;
      if (value && typeof value === 'object') {
        const annotation = value.type && (value.type !== 'None' || value.doc) ? this.typeAnnotation(value, context) : '';
        value = annotation + (annotation && value.doc ? ': ' : '') + (value.doc || '');
      }
      if (value) text += label(name) + (sections ? '' : '- ') + value + '\n';
    }
    return transformProse(this.extract(text, owner), (prose) => this.prose(prose, context));
  }
  /** Rejects member names whose heading slug would shadow a section heading. */
  sectionSafe(name, sections, context) {
    const slug = name.toLowerCase();
    if (sections.some((section) => section.toLowerCase().replaceAll(' ', '-') === slug)) throw new Error(`API member ${context}.${name} collides with a section heading`);
  }
  source(url, page = false) {
    return `\n<p class="api-source${page ? ' lg:sl-hidden' : ''}"><a href="${escapeHtml(url)}">View source</a></p>\n`;
  }
  typePage(item, symbol, owner) {
    const sections = ['Parameters', 'Fields', 'Args', 'Implemented traits', 'Returns', 'Raises', 'Constraints', 'Comptime members', 'Methods'];
    let details = this.source(this.api.symbols[symbol].source_url, true) + this.contract(item, symbol, owner, { sections: true });
    const aliasHeading = (alias) => (alias.name !== alias.name.toLowerCase() ? `\n<a id="${alias.name}"></a>\n` : '') + '\n### `' + alias.name + '`\n\n';
    if (item.aliases?.length) details += '\n## Comptime members\n';
    for (const alias of item.aliases || []) {
      this.sectionSafe(alias.name, sections, symbol);
      details += aliasHeading(alias) + '<div class="api-member">\n\n' + this.contract(alias, symbol, owner) + '\n</div>\n';
    }
    if (item.functions?.length) details += '\n## Methods\n';
    for (const member of item.functions || []) {
      this.sectionSafe(member.name, sections, symbol);
      details += '\n### `' + member.name + '`\n' + this.source(this.api.symbols[`${symbol}.${member.name}`].source_url);
      (member.overloads || [member]).forEach((overload, index) => {
        details += `\n<div class="api-member" id="${member.name}-${index}">\n\n` + this.contract(overload, symbol, owner) + '\n</div>\n';
      });
    }
    return details;
  }
  summaryList(items, link) {
    return items.map((item) => `- [\`${item.name}\`](${base}${link(item)})` + (item.summary || item.overloads?.[0]?.summary ? ': ' + (item.summary || item.overloads[0].summary) : '') + '\n').join('');
  }
  apiPages() {
    const modules = [];
    for (const module of this.decl.modules) {
      const name = module.name;
      if (name === '__init__') continue;
      if (!module.summary) throw new Error(`Missing module documentation: ${name}`);
      const route = 'larecs/' + name, owner = 'larecs/larecs_' + name;
      const sections = ['Structs', 'Traits', 'Functions', 'Comptime values'];
      let body = this.contract(module, name, owner);
      for (const [group, heading] of [['structs', 'Structs'], ['traits', 'Traits'], ['functions', 'Functions']]) {
        const items = module[group] || [];
        if (items.length) body += `\n## ${heading}\n\n` + this.summaryList(items, (item) => this.api.symbols[`${name}.${item.name}`].target);
        for (const item of items) {
          if (!item.summary && !item.overloads) throw new Error(`Missing declaration documentation: ${name}.${item.name}`);
          const symbol = `${name}.${item.name}`, target = this.api.symbols[symbol].target, itemOwner = `larecs/larecs_${name}_${item.name}`;
          let details;
          if (group === 'functions') {
            details = this.source(this.api.symbols[symbol].source_url, true);
            item.overloads.forEach((overload, index) => { details += `\n<div class="api-member" id="${item.name}-${index}">\n\n` + this.contract(overload, name, itemOwner) + '\n</div>\n'; });
          } else details = this.typePage(item, symbol, itemOwner);
          this.page(target.replace(/^\/|\/$/g, ''), item.name, details, 0, false, undefined, this.api.symbols[symbol].source_url);
        }
      }
      if (module.aliases?.length) body += '\n## Comptime values\n';
      for (const item of module.aliases || []) {
        if (!item.summary) throw new Error(`Missing declaration documentation: ${name}.${item.name}`);
        this.sectionSafe(item.name, sections, name);
        body += (item.name !== item.name.toLowerCase() ? `\n<a id="${item.name}"></a>\n` : '') + '\n### `' + item.name + '`\n\n<div class="api-member">\n\n' + this.contract(item, name, owner) + '\n</div>\n';
      }
      this.page(route, name, body);
      modules.push(module);
    }
    const summary = (qualified) => {
      const [module, item] = qualified.split('.');
      const declaration = this.decl.modules.find((entry) => entry.name === module);
      const found = ['structs', 'traits', 'functions', 'aliases'].flatMap((group) => declaration[group] || []).find((entry) => entry.name === item);
      return found?.summary || found?.overloads?.[0]?.summary || '';
    };
    const exports = Object.entries(this.api.exports).map(([name, qualified]) => `- [\`${name}\`](${base}${this.api.symbols[name].target})` + (summary(qualified) ? ': ' + summary(qualified) : '')).join('\n');
    this.page('larecs', 'API docs', '## Root exports\n\n' + exports + '\n\n## Modules\n\n' + this.summaryList(modules, (module) => `larecs/${module.name}/`));
  }
  load() {
    this.authored(); this.apiPages();
    this.page('404', 'Page not found', 'The requested page does not exist. Use the navigation or search to find it.', 0, true);
    rmSync(resolve(root, 'docs/test'), { recursive: true, force: true });
    write('docs/site/data/redirects.json', JSON.stringify(this.redirects, null, 2) + '\n');
    return [...this.pages.values()];
  }
}
