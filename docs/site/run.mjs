/** Install dependencies, then run Astro and the repository publishing checks. */
import { spawn } from 'node:child_process';
import { readdirSync, readFileSync, rmSync } from 'node:fs';
import { resolve, relative } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { createHash } from 'node:crypto';
const site = fileURLToPath(new URL('.', import.meta.url)), root = resolve(site, '../..');
const astro = resolve(site, 'node_modules/astro/bin/astro.mjs');
export function run(command, args, options = {}) {
  return new Promise((accept, reject) => {
    const process = spawn(command, args, { cwd: options.cwd || root, env: options.env || globalThis.process.env, stdio: ['inherit', 'pipe', 'pipe'] });
    let warned = false;
    for (const stream of [process.stdout, process.stderr]) stream.on('data', (data) => {
      globalThis.process.stdout.write(data);
      if (options.strict && /\[WARN\]/i.test(data.toString())) warned = true;
    });
    process.on('error', reject);
    process.on('close', (code) => code || warned ? reject(new Error(`${command} failed (exit ${code}, warnings ${warned})`)) : accept());
  });
}
function hashes() {
  const result = {};
  for (const directory of ['docs/site/public', 'docs/site/data']) {
    for (const file of readdirSync(resolve(root, directory), { withFileTypes: true, recursive: true })) {
      if (!file.isFile()) continue;
      const path = resolve(file.parentPath, file.name);
      result[relative(root, path)] = createHash('sha256').update(readFileSync(path)).digest('hex');
    }
  }
  result['docs/src/larecs.json'] = createHash('sha256').update(readFileSync(resolve(root, 'docs/src/larecs.json'))).digest('hex');
  return JSON.stringify(Object.fromEntries(Object.entries(result).sort()));
}
export async function main(command = 'build', execute = run) {
  if (!['build', 'verify', 'render', 'serve', 'watch'].includes(command)) throw new Error(`Unknown docs command: ${command}`);
  await execute('npm', ['ci'], { cwd: site });
  if (['serve', 'watch'].includes(command)) {
    await execute(process.execPath, [astro, 'dev', '--host', '127.0.0.1'], { cwd: site });
  } else {
    async function build(renderOnly = false) {
      rmSync(resolve(site, 'public'), { recursive: true, force: true });
      await execute(process.execPath, [astro, 'build'], { cwd: site, strict: true, env: { ...process.env, DOCS_RENDER_ONLY: renderOnly ? '1' : '0' } });
    }
    await build(command === 'render');
    if (command === 'verify') {
      await run(process.execPath, ['--test', 'test/content.test.mjs'], { cwd: site });
      await run('python', ['-m', 'unittest', 'test_api_reference', 'test_docs'], { cwd: resolve(root, 'scripts') });
      await run('python', ['scripts/check_docs_browser.py']);
      const before = hashes();
      await build(true);
      if (before !== hashes()) throw new Error('Documentation generation is not reproducible');
      console.log('Verified byte-identical clean Astro generation');
    }
  }

}
if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) await main(process.argv[2]);
