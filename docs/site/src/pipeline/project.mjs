import { readFileSync, readdirSync, mkdirSync, writeFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { resolve, dirname } from 'node:path';
import { parse } from 'smol-toml';

export const root = fileURLToPath(new URL('../../../../', import.meta.url));
export const site = resolve(root, 'docs/site');
export const base = process.env.DOCS_BASE_URL || 'https://larecs.github.io/larecs/dev/';
/** Classifies a deployment prefix and locates the shared Pages root. */
export function deployment(url = base, packageVersion = version) {
  const path = new URL(url).pathname;
  const release = path.match(/^(.*\/)v(\d+\.\d+\.\d+(?:(?:a|b|rc)\d+)?)\/$/);
  if (release) return { kind: 'Release', root: release[1], version: release[2], label: `v${release[2]}` };
  const preview = path.match(/^(.*\/)pr-preview\/pr-(\d+)\/$/);
  if (preview) return { kind: 'Preview', root: preview[1], version: packageVersion, label: `PR #${preview[2]} preview` };
  const development = path.match(/^(.*\/)dev\/$/);
  return { kind: 'Development', root: development ? development[1] : path, version: packageVersion, label: `Development · ${packageVersion}` };
}
export const read = (path) => readFileSync(resolve(root, path), 'utf8');
export const version = parse(read('pixi.toml')).workspace.version;
export const json = (path) => JSON.parse(read(path));
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
