import argparse
import asyncio
import re
import sys
from pathlib import Path

# modo does not set a nonzero exit code when one of its pre-run, pre-build,
# pre-test, post-test, or post-build scripts fails (observed with modo
# 0.11.13): the process itself still exits 0, and only stderr shows
# `Error: in script <phase>: exit status N`. Relying on the return code
# alone therefore lets a broken doc build (e.g. `mojo doc` erroring out, or
# a failing doctest) pass silently. Scanning the output for this line is
# the only way to catch that.
_MODO_SCRIPT_ERROR_RE = re.compile(rb"^Error: in script \S+: exit status \d+")


async def _relay(stream: asyncio.StreamReader, out) -> bool:
    """Copies a subprocess stream to `out` line by line as it arrives.

    Args:
        stream: The subprocess stream to read from.
        out: The file object (e.g. `sys.stdout`) to relay lines to.

    Returns:
        Whether a modo pre-/post-processing script error line was seen.
    """
    saw_script_error = False
    while True:
        line = await stream.readline()
        if not line:
            break
        out.buffer.write(line)
        out.flush()
        if _MODO_SCRIPT_ERROR_RE.match(line):
            saw_script_error = True
    return saw_script_error


async def _run(args, cwd) -> tuple[int, bool]:
    """Runs a command, relaying its output live as it runs.

    Args:
        args: The command and its arguments.
        cwd: The working directory to run the command in.

    Returns:
        A tuple of the process's exit code and whether a modo
        pre-/post-processing script error line was seen in its output.
    """
    proc = await asyncio.create_subprocess_exec(
        *args,
        cwd=cwd,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
    )
    stdout_error, stderr_error = await asyncio.gather(
        _relay(proc.stdout, sys.stdout),
        _relay(proc.stderr, sys.stderr),
    )
    returncode = await proc.wait()
    return returncode, stdout_error or stderr_error


def _check(returncode: int, script_error: bool, description: str) -> None:
    """Exits the process if a command failed.

    Args:
        returncode: The command's exit code.
        script_error: Whether a modo pre-/post-processing script error was
            detected in the command's output (see `_MODO_SCRIPT_ERROR_RE`).
        description: A short label for the command, used in the error message.
    """
    if returncode or script_error:
        print(
            f"error: {description} failed"
            f" (exit code {returncode}, modo script error: {script_error})",
            file=sys.stderr,
        )
        sys.exit(returncode or 1)


async def build_docs(watch=False) -> tuple[int, bool]:
    larecs_dir = Path(__file__).parent.parent

    args = ["modo", "build"]
    if watch:
        args.append("--watch")

    return await _run(args, cwd=larecs_dir)


async def build_static_site(hugo_site_dir) -> tuple[int, bool]:
    larecs_dir = Path(__file__).parent.parent
    return await _run(["hugo", "-s", hugo_site_dir], cwd=larecs_dir)


async def serve_docs(hugo_site_dir) -> tuple[int, bool]:
    larecs_dir = Path(__file__).parent.parent
    return await _run(["hugo", "server"], cwd=larecs_dir / hugo_site_dir)


async def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=["build", "serve", "watch"], default="build")
    args = parser.parse_args()

    match args.command:
        case "build":
            returncode, script_error = await build_docs()
            _check(returncode, script_error, "modo build")

            returncode, script_error = await build_static_site("docs/site")
            _check(returncode, script_error, "hugo build")

        case "watch":
            # Long-running: run both to completion (until interrupted) before
            # checking, rather than failing fast on either.
            modo_result, hugo_result = await asyncio.gather(
                build_docs(watch=True),
                serve_docs("docs/site"),
            )
            _check(*modo_result, "modo build --watch")
            _check(*hugo_result, "hugo server")

        case "serve":
            returncode, script_error = await serve_docs("docs/site")
            _check(returncode, script_error, "hugo server")


if __name__ == "__main__":
    asyncio.run(main())
