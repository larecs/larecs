"""Render the documentation's standalone Typst figures with pinned fonts."""

import subprocess
from pathlib import Path


def main() -> None:
    """Compile each non-helper source to its matching committed SVG."""
    root = Path(__file__).resolve().parent.parent
    figures = root / "docs/figures"
    output = root / "docs/site/static/images"
    for source in sorted(figures.glob("*.typ")):
        if source.name.startswith("_"):
            continue
        subprocess.run(
            [
                "typst",
                "compile",
                "--ignore-system-fonts",
                "--font-path",
                str(figures / "fonts"),
                "--format",
                "svg",
                str(source),
                str(output / source.with_suffix(".svg").name),
            ],
            check=True,
        )


if __name__ == "__main__":
    main()
