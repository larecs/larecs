"""Publish immutable release docs and the version index on the Pages branch."""

import argparse
import json
import re
import shutil
import subprocess
import tempfile
from pathlib import Path

VERSION = re.compile(r"(\d+)\.(\d+)\.(\d+)(?:(a|b|rc)(\d+))?")
PRERELEASE_ORDER = {"a": 0, "b": 1, "rc": 2}
BOT = ["-c", "user.name=github-actions[bot]",
       "-c", "user.email=41898282+github-actions[bot]@users.noreply.github.com"]


def version_key(version: str) -> tuple[int, ...] | None:
    """Return a sortable key for a release version.

    Args:
        version: Version without the leading `v`.

    Returns:
        The ordering key, or `None` when the text is not a release version.
    """
    match = VERSION.fullmatch(version)
    if not match:
        return None
    major, minor, patch, phase, number = match.groups()
    # A final release sorts after every prerelease of the same version.
    prerelease = (PRERELEASE_ORDER[phase], int(number)) if phase else (3, 0)
    return (int(major), int(minor), int(patch), *prerelease)


def releases(names) -> list[str]:
    """Return unique `v`-prefixed release names, newest first.

    Args:
        names: Candidate tag or folder names.

    Returns:
        Valid release names in descending version order.
    """
    valid = {name for name in names if name.startswith("v") and version_key(name[1:])}
    return sorted(valid, key=lambda name: version_key(name[1:]), reverse=True)


def build_manifest(pages: Path, tags, repository: str) -> dict:
    """Describe every version readers can open.

    Args:
        pages: Checkout of the Pages branch.
        tags: Repository tag names.
        repository: GitHub `owner/name` for releases without a site build.

    Returns:
        The manifest with its default path and ordered versions.

    Raises:
        ValueError: If neither a release nor development build exists.
    """
    built = releases(path.parent.name for path in pages.glob("v*/index.html"))
    versions = []
    if (pages / "dev/index.html").is_file():
        versions.append({"id": "dev", "label": "Development", "path": "dev/"})
    for index, name in enumerate(built):
        label = f"{name} (latest)" if index == 0 else name
        versions.append({"id": name, "label": label, "path": f"{name}/"})
    for name in releases(set(tags) - set(built)):
        versions.append({"id": name, "label": f"{name} (GitHub)",
                         "url": f"https://github.com/{repository}/tree/{name}"})
    default = f"{built[0]}/" if built else "dev/" if versions and versions[0]["id"] == "dev" else None
    if default is None:
        raise ValueError("The Pages branch has no release or development docs")
    return {"default": default, "versions": versions}


def redirect_page(target: str) -> str:
    """Render the Pages root redirect.

    Args:
        target: Version path relative to the Pages root.

    Returns:
        A static page that keeps the query string and fragment.
    """
    return ('<!doctype html><html lang="en"><head><meta charset="utf-8"><title>Larecs documentation</title>'
            f'<link rel="canonical" href="{target}"><meta http-equiv="refresh" content="0; url={target}">'
            f"<script>location.replace({json.dumps(target)} + location.search + location.hash);</script>"
            f'</head><body><a href="{target}">Open the Larecs documentation</a>.</body></html>\n')


def update_pages(pages: Path, tags, repository: str, build: Path | None = None, version: str | None = None) -> bool:
    """Add a release once and refresh the root files.

    Args:
        pages: Checkout of the Pages branch.
        tags: Repository tag names.
        repository: GitHub `owner/name`.
        build: Rendered release site, if publishing one.
        version: Release version without the leading `v`.

    Returns:
        Whether a new release folder was added.

    Raises:
        ValueError: If only one of `build` and `version` is given, or the
            version is invalid.
    """
    if (build is None) != (version is None):
        raise ValueError("A release deployment needs both a build and a version")
    added = False
    if version is not None:
        if not version_key(version):
            raise ValueError(f"Invalid release version: {version}")
        target = pages / f"v{version}"
        if not target.exists():
            shutil.copytree(build, target)
            added = True
    manifest = build_manifest(pages, tags, repository)
    (pages / ".nojekyll").touch()
    (pages / "versions.json").write_text(json.dumps(manifest, indent=2) + "\n")
    (pages / "index.html").write_text(redirect_page(manifest["default"]))
    return added


def git(*args: str, cwd: Path | None = None) -> str:
    """Run git and return its standard output."""
    return subprocess.run(["git", *args], cwd=cwd, check=True, text=True, capture_output=True).stdout


def deploy(repository: str, build: Path | None, version: str | None,
           remote: str = "origin", branch: str = "gh-pages", attempts: int = 10) -> None:
    """Commit the version index, retrying when another deployment lands first.

    Args:
        repository: GitHub `owner/name`.
        build: Rendered release site, if publishing one.
        version: Release version without the leading `v`.
        remote: Remote holding the Pages branch.
        branch: Pages branch name.
        attempts: Maximum number of non-force pushes.

    Raises:
        RuntimeError: If every push attempt is rejected.
    """
    tags = [line.rsplit("refs/tags/", 1)[1] for line in git("ls-remote", "--tags", "--refs", remote).splitlines()]
    tracking = f"refs/docs-versions/{branch}"
    with tempfile.TemporaryDirectory() as directory:
        pages = Path(directory) / "pages"
        git("fetch", "--depth=1", remote, f"+refs/heads/{branch}:{tracking}")
        git("worktree", "add", "--detach", str(pages), tracking)
        try:
            for _ in range(attempts):
                added = update_pages(pages, tags, repository, build, version)
                git("add", "-A", cwd=pages)
                if not git("status", "--porcelain", cwd=pages).strip():
                    print("Pages version index is current")
                    return
                subject = f"Publish docs for v{version}" if added else "Update docs version index"
                git(*BOT, "commit", "-m", subject, cwd=pages)
                head = git("rev-parse", "HEAD", cwd=pages).strip()
                if subprocess.run(["git", "push", remote, f"{head}:refs/heads/{branch}"],
                                  capture_output=True).returncode == 0:
                    print(subject)
                    return
                git("fetch", "--depth=1", remote, f"+refs/heads/{branch}:{tracking}")
                git("reset", "--hard", tracking, cwd=pages)
                git("clean", "-fdx", cwd=pages)
        finally:
            git("worktree", "remove", "--force", str(pages))
    raise RuntimeError(f"Could not update {branch} after {attempts} attempts")


def main() -> None:
    """Parse arguments and update the Pages branch."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repository", required=True, help="GitHub owner/name")
    parser.add_argument("--build", type=Path, help="Rendered release site")
    parser.add_argument("--version", help="Release version without the leading v")
    arguments = parser.parse_args()
    if (arguments.build is None) != (arguments.version is None):
        parser.error("--build and --version must be used together")
    deploy(arguments.repository, arguments.build and arguments.build.resolve(), arguments.version)


if __name__ == "__main__":
    main()
