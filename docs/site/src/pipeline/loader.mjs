import { pathToFileURL } from 'node:url';
import { resolve, relative } from 'node:path';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, mkdirSync, renameSync, rmSync } from 'node:fs';
import { root, read } from './project.mjs';
import { Documentation } from './content.mjs';

export function compileDocumentation() {
  const cache = resolve(root, 'docs/site/.astro');
  mkdirSync(cache, { recursive: true });
  const temporary = mkdtempSync(resolve(cache, 'compiler-'));
  const output = resolve(temporary, 'larecs.json');
  try {
    const result = spawnSync('pixi', ['run', '--manifest-path', resolve(root, 'pixi.toml'), 'mojo', 'doc', '-o', output, 'src/larecs'], { cwd: root, encoding: 'utf8' });
    const diagnostic = (result.stdout || '') + (result.stderr || '');
    if (result.error || result.status || /warning:/i.test(diagnostic)) throw new Error(diagnostic || String(result.error));
    JSON.parse(read(output));
    renameSync(output, resolve(root, 'docs/src/larecs.json'));
  } finally { rmSync(temporary, { recursive: true, force: true }); }

}

export function larecsLoader() {
  return {
    name: 'larecs-source-and-compiler-docs',
    async load(context) {
      async function refresh(recompile = false) {
        if (recompile) compileDocumentation();
        const docs = new Documentation(), pages = docs.load(), next = new Set();
        for (const page of pages) {
          next.add(page.id);
          const digest = context.generateDigest({ body: page.body, data: page.data });
          if (context.store.get(page.id)?.digest === digest) continue;
          // A virtual collection path keeps Starlight's file-based navigation
          // and Markdown plugins consistent without materializing Markdown.
          const filePath = resolve(root, `docs/site/src/content/docs/${page.id}.md`);
          const data = await context.parseData({ id: page.id, data: page.data, filePath });
          const rendered = await context.renderMarkdown(page.body, { fileURL: pathToFileURL(filePath) });
          context.store.set({ id: page.id, body: page.body, data, digest, rendered, filePath: relative(context.config.root.pathname, filePath) });
        }
        for (const id of context.store.keys()) if (!next.has(id)) context.store.delete(id);
        context.logger.info(`Loaded ${pages.length} source and API pages`);
      }
      await refresh();
      if (context.watcher) {
        const directories = ['docs/src', 'examples', 'src/larecs'].map((path) => resolve(root, path));
        context.watcher.add(directories);
        let pending = Promise.resolve(), timer, needsCompiler = false;
        const onChange = (path) => {
          if (!directories.some((directory) => path.startsWith(directory + '/')) || !/\.(md|mojo)$/.test(path)) return;
          needsCompiler ||= path.startsWith(directories[2]);
          clearTimeout(timer);
          timer = setTimeout(() => {
            const recompile = needsCompiler;
            needsCompiler = false;
            pending = pending.then(() => refresh(recompile)).catch((error) => context.logger.error(error.stack || error.message));
          }, 100);
        };
        for (const event of ['add', 'change', 'unlink']) context.watcher.on(event, onChange);
      }
    },
  };
}
