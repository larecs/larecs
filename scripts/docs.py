"""Build and verify Starlight documentation, executing all source examples first."""
import argparse
import hashlib
import re
import shutil
import subprocess
import sys

from api_reference import ROOT
from build_figures import build as build_figures
from check_docs import check
from docs_redirects import write_case_redirects
from render_docs import Renderer, BASE


def run(*args, cwd=ROOT):
    if 'doc' not in args and args[:3] != ('npm', 'run', 'build'):
        subprocess.run(args, cwd=cwd, check=True)
        return
    process = subprocess.Popen(args, cwd=cwd, stdout=subprocess.PIPE,
                               stderr=subprocess.STDOUT, text=True)
    warned = False
    for line in process.stdout:
        print(line, end='', flush=True)
        warned |= bool(re.search(r'\[WARN\]|warning:', line, re.I))
    if process.wait() or warned:
        raise RuntimeError(f'Documentation command failed or warned: {args}')


def generate():
    run('pixi', 'run', 'mojo', 'doc', '-o', 'docs/src/larecs.json', 'src/larecs')
    renderer = Renderer()
    renderer.generate()
    return renderer


def site(renderer):
    public = ROOT / 'docs/site/public'
    shutil.rmtree(public, ignore_errors=True)
    run('npm', 'run', 'build', cwd=ROOT / 'docs/site')
    shutil.copyfile(public / '404/index.html', public / '404.html')
    # Preserve old guide and API entry points, including incoming fragments.
    import json
    data_path = ROOT / 'docs/site/data/api.json'
    data = json.loads(data_path.read_text())
    data['case_redirects'] = renderer.redirects
    data_path.write_text(json.dumps(data, indent=2) + '\n')
    write_case_redirects(ROOT, public, BASE)
    data['case_redirects'] = renderer.api['case_redirects']
    data_path.write_text(json.dumps(data, indent=2) + '\n')
    check(ROOT)


def hashes():
    paths = []
    for directory in ('docs/site/src/content/docs', 'docs/test', 'docs/site/public', 'docs/site/data'):
        paths.extend(p for p in (ROOT / directory).rglob('*') if p.is_file())
    paths.append(ROOT / 'docs/src/larecs.json')
    return {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in paths}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=['build', 'verify', 'serve', 'watch'])
    command = parser.parse_args().command
    if command in {'serve', 'watch'}:
        generate()
        run('npm', 'run', 'dev', '--', '--host', '127.0.0.1', cwd=ROOT / 'docs/site')
        return
    run('npm', 'ci', cwd=ROOT / 'docs/site')
    renderer = generate()
    # Both build and verify gate publishing on execution, never compilation alone.
    run('pixi', 'run', 'doctest')
    run('pixi', 'run', 'docs-contracts')
    build_figures(check=True)
    site(renderer)
    if command == 'verify':
        run(sys.executable, '-m', 'unittest', 'test_api_reference', 'test_docs', cwd=ROOT / 'scripts')
        run(sys.executable, 'scripts/check_docs_browser.py')
        before = hashes()
        site(generate())
        if before != hashes():
            raise ValueError('Documentation generation is not reproducible')
        print(f'Verified byte-identical regeneration of {len(before)} files')


if __name__ == '__main__':
    main()
