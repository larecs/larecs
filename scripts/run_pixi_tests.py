"""Run Larecs tests with a v3 Mogo Tester built in its own Pixi environment."""

import hashlib
import io
import os
import subprocess
import sys
import tarfile
import tempfile
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
RUNNER_REVISION = "ed40e5326d7f8c3cc98430e74e8d625844de4c12"
RUNNER_SHA256 = "67be36991617f70d6dedae31714d6f3e349d55e77f0cd40e269f29bc9c3f477b"


def build_runner() -> Path:
    """Return the cached runner, building the pinned source on a cache miss.

    Raises:
        OSError: If the source, cache, or toolchain cannot be accessed.
        ValueError: If the downloaded source fails its checksum.
        tarfile.TarError: If the runner source archive cannot be extracted.
        subprocess.SubprocessError: If preparing or compiling the runner fails.

    Returns:
        Absolute path to the runnable Mogo Tester binary.
    """
    pixi = [
        "pixi", "run", "--locked", "--manifest-path", str(ROOT / "pixi.toml"),
        "-e", "test-runner",
    ]
    compiler = Path(subprocess.check_output([*pixi, "which", "mojo"], text=True).strip())
    cache = ROOT / ".pixi" / "mogo-tester"
    digest = hashlib.sha256(os.fsencode(compiler))
    digest.update((ROOT / "pixi.lock").read_bytes())
    digest.update(Path(__file__).read_bytes())
    key = digest.hexdigest()[:16]
    runner = cache / f"mogo-tester-{RUNNER_REVISION}-{key}"
    if runner.is_file():
        return runner

    url = f"https://codeload.github.com/moseschmiedel/mogo_tester/tar.gz/{RUNNER_REVISION}"
    with urllib.request.urlopen(url, timeout=60) as response:
        archive = response.read()
    if hashlib.sha256(archive).hexdigest() != RUNNER_SHA256:
        raise ValueError("Mogo Tester source archive checksum differs")

    cache.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="build-", dir=cache) as directory:
        scratch = Path(directory)
        with tarfile.open(fileobj=io.BytesIO(archive), mode="r:gz") as source:
            source.extractall(scratch, filter="data")
        src = scratch / f"mogo_tester-{RUNNER_REVISION}" / "src"
        output = scratch / "mogo-tester"
        command = [*pixi, "mojo", "build", "-I", str(src), "-o", str(output)]
        env = os.environ.copy()
        if sys.platform == "linux":
            # The published Linux runner uses AVX-512, which CI cannot assume.
            lib = compiler.parent.parent / "lib"
            command += [
                "--target-cpu", "x86-64-v3", "-Xlinker", f"-L{lib}",
                "-Xlinker", f"-rpath-link={lib}",
            ]
            env["MODULAR_MOJO_MAX_LINKER_DRIVER"] = str(
                Path(os.environ["CONDA_PREFIX"]) / "bin" / "clang"
            )
        command += [
            "-D", "MOGO_VERSION=v3.0.0",
            "-D", f"MOGO_COMMIT={RUNNER_REVISION}",
            str(src / "main.mojo"),
        ]
        subprocess.run(command, env=env, check=True)
        output.replace(runner)
    return runner


if __name__ == "__main__":
    runner = build_runner()
    test_script = str(ROOT / "test" / "run_tests.sh")
    os.execve(test_script, [test_script, *sys.argv[1:]], {
        **os.environ, "MOGO_TESTER_BIN": str(runner),
    })
