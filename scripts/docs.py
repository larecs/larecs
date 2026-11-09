import argparse
import asyncio
import hashlib
import os
import platform
import re
import shutil
import subprocess
import sys
from importlib.metadata import version
from pathlib import Path

from api_reference import build_reference
from build_figures import build as build_figures
from check_docs import Site, check
from docs_redirects import write_case_redirects

ROOT = Path(__file__).resolve().parent.parent

# The packaged Modo 0.11.13 launcher can return zero after strict-mode or
# hook failures. Native Modo reports a nonzero status for the same error.
# Reject the diagnostic in either case, including errors without a warning.
_MODO_ERROR_RE = re.compile(rb"^Error:")
_DOC_WARNING_RE = re.compile(rb"^(?:WARNING:|WARN\s|warning:|[^:\n]+:\d+:\d+: warning:)")
_ANSI_RE = re.compile(rb"\x1b\[[0-9;]*m")


async def _relay(stream: asyncio.StreamReader, out) -> bool:
    """Copies a subprocess stream to `out` line by line as it arrives.

    Args:
        stream: The subprocess stream to read from.
        out: The file object (e.g. `sys.stdout`) to relay lines to.

    Returns:
        Whether a Modo error or documentation warning was seen.
    """
    saw_reported_error = False
    while True:
        line = await stream.readline()
        if not line:
            break
        out.buffer.write(line)
        out.flush()
        diagnostic = _ANSI_RE.sub(b"", line)
        if _MODO_ERROR_RE.match(diagnostic) or _DOC_WARNING_RE.match(diagnostic):
            saw_reported_error = True
    return saw_reported_error


async def _run(args, cwd) -> tuple[int, bool]:
    """Runs a command, relaying its output live as it runs.

    Args:
        args: The command and its arguments.
        cwd: The working directory to run the command in.

    Returns:
        A tuple of the process's exit code and whether a Modo error or
        documentation warning was seen in its output.
    """
    proc = await asyncio.create_subprocess_exec(
        *args,
        cwd=cwd,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
    )
    relay_tasks = [
        asyncio.create_task(_relay(proc.stdout, sys.stdout)),
        asyncio.create_task(_relay(proc.stderr, sys.stderr)),
    ]
    try:
        stdout_error, stderr_error = await asyncio.gather(*relay_tasks)
        returncode = await proc.wait()
        return returncode, stdout_error or stderr_error
    except asyncio.CancelledError:
        # Watch mode cancels the still-running command when its sibling exits.
        # Ensure cancellation does not orphan that subprocess.
        if proc.returncode is None:
            proc.terminate()
        await proc.wait()
        raise


def _check(returncode: int, reported_error: bool, description: str) -> None:
    """Exits the process if a command failed.

    Args:
        returncode: The command's exit code.
        reported_error: Whether a Modo error or documentation warning was
            detected in the command's output.
        description: A short label for the command, used in the error message.
    """
    if returncode or reported_error:
        print(
            f"error: {description} failed"
            f" (exit code {returncode}, documentation diagnostics: {reported_error})",
            file=sys.stderr,
        )
        sys.exit(returncode or 1)


def _modo_executable() -> str:
    """Returns the Modo executable to run.

    pymodo bundles only an x86_64 macOS binary, which fails with `Bad CPU
    type in executable` on Apple Silicon without Rosetta. There, the same
    Modo release is built natively from source with the Go toolchain of the
    docs environment and cached under `scripts/.pixi/modo/<version>/`.

    Returns:
        The path or name of the Modo executable.
    """
    if sys.platform != "darwin" or platform.machine() != "arm64":
        return "modo"

    modo_version = version("pymodo")
    bin_dir = Path(__file__).parent / ".pixi" / "modo" / modo_version
    executable = bin_dir / "modo"
    if not executable.exists():
        print(f"Building Modo v{modo_version} for arm64...", flush=True)
        subprocess.run(
            ["go", "install", f"github.com/mlange-42/modo@v{modo_version}"],
            env=os.environ | {"GOBIN": str(bin_dir), "CGO_ENABLED": "0"},
            check=True,
        )
    return str(executable)


async def build_docs(watch=False, bare=False) -> tuple[int, bool]:
    larecs_dir = Path(__file__).parent.parent

    args = [_modo_executable(), "build"]
    if watch:
        args.append("--watch")
    if bare:
        args.append("--bare")

    return await _run(args, cwd=larecs_dir)


async def build_static_site(hugo_site_dir) -> tuple[int, bool]:
    larecs_dir = Path(__file__).parent.parent
    shutil.rmtree(larecs_dir / hugo_site_dir / "public", ignore_errors=True)
    result = await _run(["hugo", "-s", hugo_site_dir, "--panicOnWarning"], cwd=larecs_dir)
    if not any(result):
        site = Site(larecs_dir)
        write_case_redirects(larecs_dir, site.public, site.base)
    return result


def generated_hashes() -> dict[str, str]:
    """Hash disposable outputs at a fixed revision and deployment URL."""
    paths = [ROOT / "docs/src/larecs.json", ROOT / "docs/site/data/api.json"]
    for directory in ("docs/site/content", "docs/test", "docs/site/public"):
        paths.extend(path for path in (ROOT / directory).rglob("*") if path.is_file())
    return {str(path.relative_to(ROOT)): hashlib.sha256(path.read_bytes()).hexdigest()
            for path in sorted(paths)}


async def verify_reproduction() -> None:
    """Regenerate from clean outputs and compare compiler, Markdown, tests and HTML."""
    before = generated_hashes()
    for directory in ("docs/site/content", "docs/test", "docs/site/public"):
        shutil.rmtree(ROOT / directory)
    for path in ("docs/src/larecs.json", "docs/site/data/api.json"):
        (ROOT / path).unlink()
    result = await _run(["pixi", "run", "--manifest-path", "pixi.toml", "mojo", "doc",
                         "-o", "docs/src/larecs.json", "src/larecs"], cwd=ROOT)
    _check(*result, "clean compiler JSON")
    _check(*(await build_docs(bare=True)), "clean Modo generation")
    build_reference()
    _check(*(await build_static_site("docs/site")), "clean Hugo generation")
    check(ROOT)
    after = generated_hashes()
    changed = [path for path in before.keys() | after.keys() if before.get(path) != after.get(path)]
    if changed:
        raise ValueError(f"Non-reproducible documentation outputs: {sorted(changed)}")
    print(f"Verified byte-identical clean generation of {len(after)} files")


async def serve_docs(hugo_site_dir) -> tuple[int, bool]:
    larecs_dir = Path(__file__).parent.parent
    return await _run(["hugo", "server"], cwd=larecs_dir / hugo_site_dir)


async def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=["build", "verify", "serve", "watch"], default="build")
    args = parser.parse_args()

    match args.command:
        case "build" | "verify":
            returncode, reported_error = await build_docs()
            _check(returncode, reported_error, "modo build")
            build_figures(check=True)

            returncode, reported_error = await build_static_site("docs/site")
            _check(returncode, reported_error, "hugo build")
            check(Path(__file__).parent.parent)
            if args.command == "verify":
                result = await _run([sys.executable, "check_docs_browser.py"], cwd=Path(__file__).parent)
                _check(*result, "documentation browser checks")
                result = await _run([sys.executable, "-m", "unittest", "test_api_reference", "test_docs"],
                                    cwd=Path(__file__).parent)
                _check(*result, "documentation integration checks")
                await verify_reproduction()

        case "watch":
            # Both commands are long-running, but either one must be able to
            # report its failure while the other is still alive.
            modo_task = asyncio.create_task(build_docs(watch=True))
            hugo_task = asyncio.create_task(serve_docs("docs/site"))
            done, pending = await asyncio.wait(
                (modo_task, hugo_task),
                return_when=asyncio.FIRST_COMPLETED,
            )

            for task in pending:
                task.cancel()
            await asyncio.gather(*pending, return_exceptions=True)

            for completed_task in done:
                completed_result = completed_task.result()
                if completed_task is modo_task:
                    _check(*completed_result, "modo build --watch")
                else:
                    _check(*completed_result, "hugo server")

        case "serve":
            returncode, reported_error = await serve_docs("docs/site")
            _check(returncode, reported_error, "hugo server")


if __name__ == "__main__":
    asyncio.run(main())
