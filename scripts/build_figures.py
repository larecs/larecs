"""Render the documentation's standalone Typst figures with pinned fonts."""

import argparse
import subprocess
import tempfile
from pathlib import Path


def build(check=False) -> None:
    """Compile every figure, or reject drift from the committed SVG exports."""
    root = Path(__file__).resolve().parent.parent
    figures = root / "docs/figures"
    output = root / "docs/site/static/images"
    sources = [path for path in sorted(figures.glob("*.typ")) if not path.name.startswith("_")]
    if not sources:
        raise ValueError("No documentation figure sources found")
    if check and {path.stem for path in sources} != {path.stem for path in output.glob("*.svg")}:
        raise ValueError("Figure source/export inventory differs")
    with tempfile.TemporaryDirectory() as directory:
        for source in sources:
            committed = output / source.with_suffix(".svg").name
            target = Path(directory) / committed.name if check else committed
            subprocess.run(
                [
                    "typst", "compile", "--ignore-system-fonts",
                    "--font-path", str(figures / "fonts"), "--format", "svg",
                    str(source), str(target),
                ],
                check=True,
            )
            if check and (not committed.is_file() or target.read_bytes() != committed.read_bytes()):
                raise ValueError(f"Stale figure export: {committed.relative_to(root)}; run pixi run figures")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true")
    build(parser.parse_args().check)
