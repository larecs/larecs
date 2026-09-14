"""Update Mojo dependency pins across the repository."""

from __future__ import annotations

import argparse
import json
import re
import subprocess
from pathlib import Path
from typing import Any

MOJO_VERSION_FILES = [
    Path("pixi.toml"),
    Path("conda.recipe/recipe.yaml"),
    Path("conda.recipe/recipe-latest-release.yaml"),
    Path("examples/satellites/pixi.toml"),
    Path("benchmark/plots/pixi.toml"),
    Path("benchmark/compile/pixi.toml"),
]

MOJO_SEARCH_CHANNELS = [
    "https://repo.prefix.dev/max",
    "conda-forge",
]

DEFAULT_MAX_VERSION = "2"

TOML_MOJO_RE = re.compile(r'^(\s*mojo\s*=\s*")[^"]*(".*)$')
YAML_MOJO_COMPILER_RE = re.compile(r"^(\s*-\s*mojo-compiler\s+).*$")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Update all configured Mojo dependency pins to one version."
    )
    parser.add_argument(
        "version",
        nargs="?",
        help="Mojo version to use. Defaults to the newest version found by pixi search.",
    )
    parser.add_argument(
        "--max-version",
        default=DEFAULT_MAX_VERSION,
        help=f"Exclusive upper bound for Mojo constraints. Defaults to {DEFAULT_MAX_VERSION}.",
    )
    parser.add_argument(
        "--no-update-lock",
        action="store_true",
        help="Skip running pixi lock in each configured Pixi project after editing pins.",
    )
    return parser.parse_args()


def repo_root() -> Path:
    return Path(__file__).resolve().parents[1]


def run_command(command: list[str], *, cwd: Path) -> subprocess.CompletedProcess[str]:
    try:
        return subprocess.run(
            command,
            cwd=cwd,
            check=True,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
    except FileNotFoundError as exc:
        raise RuntimeError(f"Command not found: {command[0]}") from exc
    except subprocess.CalledProcessError as exc:
        output = "\n".join(part for part in (exc.stdout, exc.stderr) if part)
        raise RuntimeError(f"Command failed: {' '.join(command)}\n{output}") from exc


def extract_json(text: str) -> Any:
    decoder = json.JSONDecoder()
    for index, char in enumerate(text):
        if char not in "[{":
            continue
        try:
            value, _ = decoder.raw_decode(text[index:])
        except json.JSONDecodeError:
            continue
        return value
    raise RuntimeError("pixi search did not return JSON output")


def collect_versions(value: Any) -> list[str]:
    if isinstance(value, dict):
        versions: list[str] = []
        for key, child in value.items():
            if key == "version" and isinstance(child, str):
                versions.append(child)
            else:
                versions.extend(collect_versions(child))
        return versions

    if isinstance(value, list):
        versions = []
        for child in value:
            versions.extend(collect_versions(child))
        return versions

    return []


def version_key(version: str) -> tuple[tuple[int, Any], ...]:
    parts = re.findall(r"\d+|[A-Za-z]+", version)
    key: list[tuple[int, Any]] = []
    for part in parts:
        if part.isdigit():
            key.append((1, int(part)))
        else:
            key.append((0, part.lower()))
    return tuple(key)


def newest_mojo_version(root: Path) -> str:
    command = ["pixi", "search", "--json"]
    for channel in MOJO_SEARCH_CHANNELS:
        command.extend(["--channel", channel])
    command.append("mojo")

    result = run_command(command, cwd=root)
    versions = collect_versions(extract_json(result.stdout))
    if not versions:
        raise RuntimeError("No Mojo versions found in pixi search output")

    return max(versions, key=version_key)


def update_file(path: Path, version: str, max_version: str) -> int:
    if not path.exists():
        raise RuntimeError(f"Configured Mojo version file does not exist: {path}")

    toml_constraint = f">={version},<{max_version}"
    yaml_constraint = f">={version}, <{max_version}"

    changes = 0
    updated_lines: list[str] = []
    for line in path.read_text().splitlines(keepends=True):
        newline = "\n" if line.endswith("\n") else ""
        content = line[:-1] if newline else line

        toml_match = TOML_MOJO_RE.match(content)
        if toml_match:
            updated_lines.append(
                f"{toml_match.group(1)}{toml_constraint}{toml_match.group(2)}{newline}"
            )
            changes += 1
            continue

        yaml_match = YAML_MOJO_COMPILER_RE.match(content)
        if yaml_match:
            updated_lines.append(f"{yaml_match.group(1)}{yaml_constraint}{newline}")
            changes += 1
            continue

        updated_lines.append(line)

    if changes == 0:
        raise RuntimeError(f"No Mojo dependency pin found in configured file: {path}")

    path.write_text("".join(updated_lines))
    return changes


def update_mojo_files(root: Path, version: str, max_version: str) -> dict[Path, int]:
    changed_files: dict[Path, int] = {}
    for relative_path in MOJO_VERSION_FILES:
        path = root / relative_path
        changes = update_file(path, version, max_version)
        changed_files[relative_path] = changes
    return changed_files


def pixi_project_dirs(root: Path) -> list[Path]:
    dirs = []
    seen: set[Path] = set()
    for relative_path in MOJO_VERSION_FILES:
        if relative_path.name != "pixi.toml":
            continue

        project_dir = (root / relative_path).parent
        if project_dir in seen:
            continue

        seen.add(project_dir)
        dirs.append(project_dir)
    return dirs


def update_locks(root: Path) -> None:
    for project_dir in pixi_project_dirs(root):
        print(f"Updating Pixi lock in {project_dir.relative_to(root)}")
        run_command(["pixi", "lock"], cwd=project_dir)


def main() -> int:
    args = parse_args()
    root = repo_root()
    version = args.version or newest_mojo_version(root)

    changed_files = update_mojo_files(root, version, args.max_version)
    if not args.no_update_lock:
        update_locks(root)

    print(f"Updated Mojo dependency pins to >={version}, <{args.max_version}:")
    for relative_path, changes in changed_files.items():
        print(f"  {relative_path}: {changes} replacement(s)")

    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        raise SystemExit(str(exc))
