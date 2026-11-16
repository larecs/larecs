"""Manage changelog fragments in changelog.d/.

Every feature branch keeps its changelog entries in one Markdown fragment,
changelog.d/<feature>.md, so entries travel with the branch into `nightly` and
`main` without conflicting with other features. A fragment groups bullet
entries under `### <section>` headings, using the sections in SECTIONS. Each
entry ends with links to the PRs that shaped the feature.

Commands:
    check    Fail unless the branch adds or changes a fragment relative to a
             base, optionally requiring a link to a given PR.
    preview  Print the unreleased changes collected from all fragments.
    release  Move all fragments into a new version section of changelog.md and
             delete them.

Usage:
    python3 scripts/changelog.py check --base origin/nightly --pr 42 --require-link
    python3 scripts/changelog.py preview
    python3 scripts/changelog.py release 1.0.0b3 --previous 1.0.0b2
"""

import argparse
import datetime
import re
import subprocess
import sys
from pathlib import Path

REPO = "larecs/larecs"
FRAGMENTS = Path("changelog.d")
CHANGELOG = Path("changelog.md")
SECTIONS = ["Breaking changes", "Added", "Changed", "Fixed", "Removed"]
IGNORED = {"README.md"}


def fragment_paths() -> list[Path]:
    """Return the fragment files in a stable order."""
    return sorted(
        p for p in FRAGMENTS.glob("*.md") if p.name not in IGNORED
    )


def parse_fragment(path: Path) -> dict[str, list[str]]:
    """Split a fragment into its entries per section.

    Raises SystemExit when the fragment uses an unknown section or has text
    outside a section.
    """
    sections: dict[str, list[str]] = {}
    current = None
    entry: list[str] = []

    def flush() -> None:
        if entry and current is not None:
            sections.setdefault(current, []).append("\n".join(entry).rstrip())
        entry.clear()

    for number, line in enumerate(path.read_text().splitlines(), start=1):
        heading = re.match(r"^###\s+(.+?)\s*$", line)
        if heading:
            flush()
            current = heading.group(1)
            if current not in SECTIONS:
                sys.exit(
                    f"error: {path}:{number}: unknown section '{current}'; "
                    f"use one of {', '.join(SECTIONS)}"
                )
        elif line.startswith("- "):
            flush()
            if current is None:
                sys.exit(f"error: {path}:{number}: entry outside a '### <section>'")
            entry.append(line)
        elif line.strip() and entry:
            entry.append(line)
        elif line.strip():
            sys.exit(f"error: {path}:{number}: text outside an entry")
    flush()
    if not sections:
        sys.exit(f"error: {path}: no entries")
    return sections


def collect() -> dict[str, list[str]]:
    """Merge the entries of all fragments by section."""
    merged: dict[str, list[str]] = {}
    for path in fragment_paths():
        for section, entries in parse_fragment(path).items():
            merged.setdefault(section, []).extend(entries)
    return merged


def render(merged: dict[str, list[str]]) -> str:
    """Render merged entries as changelog sections."""
    blocks = []
    for section in SECTIONS:
        if merged.get(section):
            blocks.append(f"### {section}\n\n" + "\n\n".join(merged[section]))
    return "\n\n".join(blocks)


def changed_fragments(base: str) -> list[Path]:
    """Return fragments added or modified since the merge base with `base`."""
    out = subprocess.run(
        ["git", "diff", "--name-only", "--diff-filter=AM", f"{base}...HEAD", "--", str(FRAGMENTS)],
        check=True,
        capture_output=True,
        text=True,
    ).stdout
    return [Path(p) for p in out.split() if Path(p).name not in IGNORED]


def check(base: str, pr: int | None, require_link: bool) -> None:
    changed = changed_fragments(base)
    if not changed:
        sys.exit(
            f"error: add or update a fragment in {FRAGMENTS}/ for this change, "
            f"or label the PR 'no-changelog'"
        )
    for path in changed:
        parse_fragment(path)
    if require_link:
        link = f"[#{pr}](https://github.com/{REPO}/pull/{pr})"
        if not any(link in p.read_text() for p in changed):
            sys.exit(f"error: link this PR as {link} from the entries it adds or changes")
    print("Changelog fragments: " + ", ".join(str(p) for p in changed))


def preview() -> None:
    print(render(collect()) or "No unreleased changes.")


def release(version: str, previous: str, date: str) -> None:
    body = render(collect())
    if not body:
        sys.exit("error: no fragments to release")
    text = CHANGELOG.read_text()
    unreleased = re.search(r"^## \[Unreleased\].*?\n(?=## )", text, flags=re.M | re.S)
    if unreleased is None:
        sys.exit("error: changelog.md needs an '## [Unreleased]' section above the releases")
    heading = (
        f"## [{version} ({date})]"
        f"(https://github.com/{REPO}/compare/v{previous}...v{version})"
    )
    section = f"{heading}\n\n{body}\n\n"
    end = unreleased.end()
    text = text[:end] + section + text[end:]
    # Unreleased now compares against the new release.
    text = re.sub(
        r"^(## \[Unreleased\]\(https://github\.com/[^)]*/compare/)v[^.)]+(?:\.[^.)]+)*?\.\.\.",
        rf"\g<1>v{version}...",
        text,
        count=1,
        flags=re.M,
    )
    CHANGELOG.write_text(text)
    for path in fragment_paths():
        path.unlink()
    print(f"Added {version} to {CHANGELOG} and removed the released fragments.")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest="command", required=True)
    p_check = sub.add_parser("check")
    p_check.add_argument("--base", required=True, help="branch the PR merges into")
    p_check.add_argument("--pr", type=int)
    p_check.add_argument("--require-link", action="store_true")
    sub.add_parser("preview")
    p_release = sub.add_parser("release")
    p_release.add_argument("version")
    p_release.add_argument("--previous", required=True, help="previous release version")
    p_release.add_argument(
        "--date", default=datetime.date.today().isoformat(), help="release date (YYYY-MM-DD)"
    )
    args = parser.parse_args()
    if args.command == "check":
        if args.require_link and args.pr is None:
            parser.error("--require-link needs --pr")
        check(args.base, args.pr, args.require_link)
    elif args.command == "preview":
        preview()
    else:
        release(args.version, args.previous, args.date)


if __name__ == "__main__":
    main()
