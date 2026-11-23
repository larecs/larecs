import { execFileSync } from 'node:child_process';
import { existsSync, statSync, readFileSync, writeFileSync, mkdirSync, copyFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { base, root, json, escapeHtml, deployment } from './project.mjs';
import { compileDocumentation } from './loader.mjs';

export function writeRedirects(publicDir) {
  const redirects = json('docs/site/data/redirects.json');
  for (const [route, target] of Object.entries(redirects)) {
    const path = resolve(publicDir, route, 'index.html'), module = resolve(publicDir, route.toLowerCase(), 'index.html');
    const destination = new URL(target, base).href;
    const script = `<script data-legacy-redirect>if (location.pathname === ${JSON.stringify(new URL(route, base).pathname)}) location.replace(${JSON.stringify(destination)} + location.hash);</script>`;
    if (existsSync(path) && existsSync(module) && statSync(path).ino === statSync(module).ino) {
      const text = readFileSync(module, 'utf8');
      if (text.includes('data-legacy-redirect')) throw new Error('Case redirects require a clean Astro destination');
      writeFileSync(module, text.replace('</body>', script + '</body>'));
    } else {
      mkdirSync(dirname(path), { recursive: true });
      const escaped = escapeHtml(destination);
      writeFileSync(path, `<!doctype html><html lang="en"><head><meta charset="utf-8"><title>Page moved</title><link rel="canonical" href="${escaped}"><meta http-equiv="refresh" content="0; url=${escaped}">${script}</head><body><a href="${escaped}">Continue to the current page</a>.</body></html>\n`);
    }
  }
  copyFileSync(resolve(publicDir, '404/index.html'), resolve(publicDir, '404.html'));
}

export function larecsDocumentation() {
  return {
    name: 'larecs-documentation',
    hooks: {
      'astro:config:setup': ({ updateConfig }) => {
        compileDocumentation();
        updateConfig({ vite: { plugins: [{
          name: 'larecs-project-metadata',
          resolveId(id) { if (id === 'virtual:larecs/project') return '\0larecs-project'; },
          load(id) { if (id === '\0larecs-project') return `export const site = ${JSON.stringify({ ...deployment(), base: new URL(base).pathname })};`; },
        }] } });
      },
      'astro:build:setup': () => {
        if (process.env.DOCS_RENDER_ONLY === '1') return;
        for (const args of [['run', '--manifest-path', resolve(root, 'pixi.toml'), 'doctest'], ['run', '--manifest-path', resolve(root, 'pixi.toml'), 'docs-contracts']]) execFileSync('pixi', args, { cwd: root, stdio: 'inherit' });
        execFileSync('python', ['scripts/build_figures.py', '--check'], { cwd: root, stdio: 'inherit' });
      },
      'astro:build:done': ({ dir }) => {
        writeRedirects(fileURLToPath(dir));
        execFileSync('python', ['scripts/check_docs.py'], { cwd: root, stdio: 'inherit' });
      },
    },
  };
}
