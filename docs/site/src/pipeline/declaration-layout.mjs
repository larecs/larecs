/** Whitespace-only layout for declarations containing compiler-only syntax. */
export const tokens = (text) => text.match(/"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|[\[\](){},]|\s+|[^\[\](){},\s"']+|./gs) || [];
const pairs = { '[': ']', '(': ')', '{': '}' };
const header = /^(?:async\s+)?(def|struct|trait|comptime)\s+\w+$/;
function entries(parts) {
  const result = [];
  let entry = [];
  for (const part of parts) {
    if (part === ',') { result.push([entry, true]); entry = []; }
    else entry.push(part);
  }
  if (entry.some((part) => typeof part !== 'string' || part.trim())) result.push([entry, false]);
  return result;
}
function flat(parts) {
  return parts.map((part) => {
    if (typeof part === 'string') return part;
    const items = entries(part.parts);
    return part.opening + items.map(([entry]) => flat(entry).trim()).join(', ') + (items.at(-1)?.[1] ? ',' : '') + part.closing;
  }).join('');
}
export function formatDeclaration(text, width = 80) {
  const root = { parts: [] }, stack = [root];
  for (const token of tokens(text.trim())) {
    if (Object.hasOwn(pairs, token)) {
      const group = { opening: token, parts: [], closing: '' };
      stack.at(-1).parts.push(group); stack.push(group);
    } else if (Object.values(pairs).includes(token)) {
      if (stack.length === 1 || pairs[stack.at(-1).opening] !== token) throw new Error('Unbalanced declaration delimiters');
      stack.pop().closing = token;
    } else stack.at(-1).parts.push(/^\s+$/.test(token) ? ' ' : token);
  }
  if (stack.length !== 1) throw new Error('Unclosed declaration delimiter');
  const compact = flat(root.parts).trim();
  if (compact.length <= width) return compact;
  const forced = new Set();
  let prefix = '';
  for (const part of root.parts) {
    if (typeof part === 'string') { prefix += part; continue; }
    if (header.test(prefix.trim()) && ['[', '('].includes(part.opening)) {
      forced.add(part);
      if (part.opening === '[') { prefix = ''; continue; }
    } else if (!prefix.trim() && forced.size && part.opening === '(') forced.add(part);
    break;
  }
  function render(parts, indent = 0, prefix = '', trailing = 0) {
    let output = prefix;
    parts.forEach((part, index) => {
      if (typeof part === 'string') {
        // Existing delimiters allow line continuation before expression
        // operators and conditional clauses without adding syntax.
        const next = parts[index + 1];
        const breakpoint = typeof next === 'string' && /^(?:if|else|and|or|\+|-|&|\|)$/.test(next);
        if (indent > 0 && /^\s+$/.test(part) && breakpoint && output.split('\n').at(-1).length + flat(parts.slice(index)).length + trailing > width) output += '\n' + ' '.repeat(indent);
        else output += part;
        return;
      }
      const inline = flat([part]), column = output.split('\n').at(-1).length, items = entries(part.parts);
      let suffix = trailing;
      for (const following of parts.slice(index + 1)) {
        if (typeof following !== 'string') { suffix += following.opening.length - trailing; break; }
        suffix += following.length;
      }
      if (!items.length || (!forced.has(part) && column + inline.length + suffix <= width)) { output += inline; return; }
      output += part.opening;
      for (let [entry, comma] of items) {
        entry = [...entry];
        while (typeof entry[0] === 'string' && !entry[0].trim()) entry.shift();
        while (typeof entry.at(-1) === 'string' && !entry.at(-1).trim()) entry.pop();
        output += '\n' + render(entry, indent + 4, ' '.repeat(indent + 4), Number(comma)) + (comma ? ',' : '');
      }
      output += '\n' + ' '.repeat(indent) + part.closing;
    });
    return output;
  }
  return render(root.parts).trim();
}
