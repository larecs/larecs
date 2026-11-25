"""Manage changelog fragments in changelog.d/.

Each feature records its changelog entries in changelog.d/<feature>.md.
Fragments group bullet entries under `### <section>` headings from SECTIONS.
Each entry ends with links to the PRs that shaped the feature.

Commands:
    preview  Print the unreleased changes collected from all fragments.
    release  Move all fragments into a new version section of changelog.md and
             delete them.

Usage:
    python3 scripts/changelog.py preview
    python3 scripts/changelog.py release 1.0.0b3 --previous 1.0.0b2
"""

import argparse
import datetime
import re
import sys
from pathlib import Path

REPO = "larecs/larecs"
FRAGMENTS = Path("changelog.d")
CHANGELOG = Path("changelog.md")
SECTIONS = ["Breaking changes", "Added", "Changed", "Fixed", "Removed"]
IGNORED = {"README.md"}


def fragment_paths() -> list[Path]:
    """Find the changelog fragments.

    Returns:
        Markdown fragment paths sorted by name, excluding README.md.
    """
    return sorted(
        p for p in FRAGMENTS.glob("*.md") if p.name not in IGNORED
    )


def parse_fragment(path: Path) -> dict[str, list[str]]:
    """Parse the sections and bullet entries in one fragment.

    Args:
        path: Path to the Markdown fragment.

    Raises:
        SystemExit: If the fragment has an unknown section, misplaced text, or no entries.
        OSError: If the fragment cannot be read.
        UnicodeError: If the fragment cannot be decoded.

    Returns:
        A mapping from section headings to their entries in file order.
    """
    sections: dict[str, list[str]] = {}
    current = None
    entry: list[str] = []

    def flush() -> None:
        """Save the buffered entry to the current section and clear the buffer."""
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
    """Merge the entries of all fragments by section.

    Raises:
        SystemExit: If a fragment is malformed or empty.
        OSError: If a fragment cannot be read.
        UnicodeError: If a fragment cannot be decoded.

    Returns:
        A mapping from section headings to entries in fragment and file order.
    """
    merged: dict[str, list[str]] = {}
    for path in fragment_paths():
        for section, entries in parse_fragment(path).items():
            merged.setdefault(section, []).extend(entries)
    return merged


def render(merged: dict[str, list[str]]) -> str:
    """Render entries in changelog section order.

    Args:
        merged: Entries grouped by section heading.

    Returns:
        Markdown for nonempty sections, or an empty string when there are no entries.
    """
    blocks = []
    for section in SECTIONS:
        if merged.get(section):
            blocks.append(f"### {section}\n\n" + "\n\n".join(merged[section]))
    return "\n\n".join(blocks)


def preview() -> None:
    """Print unreleased changes without modifying the changelog or fragments.

    Raises:
        SystemExit: If a fragment is malformed or empty.
        OSError: If a fragment cannot be read or the preview cannot be printed.
        UnicodeError: If a fragment cannot be decoded.
    """
    print(render(collect()) or "No unreleased changes.")


def release(version: str, previous: str, date: str) -> None:
    """Insert a release section in the changelog and remove its fragments.

    Args:
        version: New release version without the leading `v`.
        previous: Previous release version without the leading `v`.
        date: Release date in YYYY-MM-DD format.

    Raises:
        SystemExit: If there are no entries, a fragment is malformed, or the
            changelog lacks an Unreleased section above a release heading.
        OSError: If reading, writing, or removing a file fails.
        UnicodeError: If changelog or fragment text cannot be decoded or encoded.
    """
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
    """Parse command-line arguments and run the requested changelog command.

    Raises:
        SystemExit: If help is requested, arguments are invalid, or the
            selected command rejects the changelog or its fragments.
        OSError: If command input or output fails.
        UnicodeError: If command input or output cannot be decoded or encoded.
    """
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("preview")
    p_release = sub.add_parser("release")
    p_release.add_argument("version")
    p_release.add_argument("--previous", required=True, help="previous release version")
    p_release.add_argument(
        "--date", default=datetime.date.today().isoformat(), help="release date (YYYY-MM-DD)"
    )
    args = parser.parse_args()
    if args.command == "preview":
        preview()
    else:
        release(args.version, args.previous, args.date)


if __name__ == "__main__":
    main()
