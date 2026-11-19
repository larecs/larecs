import { readFileSync, readdirSync, mkdirSync, writeFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { resolve, dirname } from 'node:path';
import { parse } from 'smol-toml';

export const root = fileURLToPath(new URL('../../../../', import.meta.url));
export const site = resolve(root, 'docs/site');
export const base = process.env.DOCS_BASE_URL || 'https://larecs.github.io/larecs/dev/';
export const read = (path) => readFileSync(resolve(root, path), 'utf8');
export const json = (path) => JSON.parse(read(path));
export const version = parse(read('pixi.toml')).workspace.version;
export function write(path, text) {
  const target = resolve(root, path);
  mkdirSync(dirname(target), { recursive: true });
  writeFileSync(target, text);
}
export function files(directory, extension) {
  return readdirSync(resolve(root, directory), { withFileTypes: true, recursive: true })
    .filter((entry) => entry.isFile() && entry.name.endsWith(extension))
    .map((entry) => resolve(entry.parentPath, entry.name)).sort();
}
export const escapeHtml = (value) => String(value).replace(/[&<>"']/g, (char) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#x27;' })[char]);
