"""Build the API symbol map from compiler declarations and checked root imports."""

import ast
import json
import re
import subprocess
import tomllib
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def root_exports(source: str) -> dict[str, str]:
    """Return root names and defining paths, rejecting manual export drift.

    Args:
        source: Contents of the package initializer.

    Returns:
        Root import names mapped to module-qualified declarations.
    """
    imports = ast.parse(source[source.index("from .world import"):])
    exports = {
        alias.asname or alias.name: f"{node.module}.{alias.name}"
        for node in imports.body
        if isinstance(node, ast.ImportFrom)
        for alias in node.names
    }
    manual = re.findall(r"^ - ([\w.]+)$", source, re.MULTILINE)
    if set(manual) != set(exports.values()) or len(manual) != len(exports):
        raise ValueError("Exports list differs from package imports")
    return exports


def build_reference(root: Path = ROOT) -> dict:
    """Write symbol metadata and compatibility redirects for generated pages.

    Args:
        root: Repository containing compiler JSON and Modo output.

    Returns:
        Revision, version, and symbol metadata used by Hugo.
    """
    declaration = json.loads((root / "docs/src/larecs.json").read_text())["decl"]
    exports = root_exports((root / "src/larecs/__init__.mojo").read_text())
    revision = subprocess.check_output(
        ["git", "rev-parse", "HEAD"], cwd=root, text=True
    ).strip()
    symbols = {}
    content = root / "docs/site/content"

    def add(name, target, source):
        """Register a declaration under its defining import path."""
        source_text = (root / source).read_text()
        parts = name.split(".")[1:]
        position = 0
        for part in parts:
            match = re.search(r"(?m)^[ \t]*(?:def|struct|trait|comptime) " + re.escape(part.split("-", 1)[0]) + r"(?:\W|$)", source_text[position:])
            if match:
                position += match.start()
        line = source_text[:position].count("\n") + 1
        symbols[f"larecs.{name}"] = {
            "target": target, "source": source, "line": line,
            "source_url": f"https://github.com/larecs/larecs/blob/{revision}/{source}#L{line}",
        }
        symbols[name] = symbols[f"larecs.{name}"]

    for module in declaration["modules"]:
        module_name = module["name"]
        if module_name == "__init__":
            continue
        source = f"src/larecs/{module_name}.mojo"
        for group in ("structs", "traits", "functions", "aliases"):
            for item in module.get(group, []):
                name = item["name"]
                if group == "aliases":
                    target = f"larecs/{module_name}/#{name}"
                else:
                    target = f"larecs/{module_name}/{name}/"
                qualified = f"{module_name}.{name}"
                add(qualified, target, source)
                for member_group in ("functions", "aliases"):
                    for member in item.get(member_group, []):
                        member_name = member["name"]
                        anchor = member_name if member_group == "aliases" else member_name.lower()
                        add(f"{qualified}.{member_name}", target + "#" + anchor, source)
                        for i, _ in enumerate(member.get("overloads", [])):
                            if len(member["overloads"]) > 1:
                                add(f"{qualified}.{member_name}-{i}", target + f"#{member_name}-{i}", source)

    # Unambiguous short names remain valid link labels, independent of imports.
    short_names = {}
    for key in list(symbols):
        if not key.startswith("larecs."):
            short_names.setdefault(key.split(".", 1)[1], []).append(key)
    for short, candidates in short_names.items():
        if len(candidates) == 1:
            symbols[short] = symbols[candidates[0]]

    for name, qualified in exports.items():
        key = f"larecs.{qualified}"
        if key not in symbols:
            raise ValueError(f"Root export missing from compiler JSON: {qualified}")
        for symbol, metadata in list(symbols.items()):
            if symbol == key or symbol.startswith(key + "."):
                suffix = symbol[len(key):]
                symbols[name + suffix] = metadata
                symbols["larecs." + name + suffix] = metadata

    # Keep old generated URLs, including formerly documented module-only types.
    legacy = {
        **exports,
        "ComponentManager": "component.ComponentManager",
        "DeviceComponentStorage": "device_storage.DeviceComponentStorage",
        "DeviceResourceStorage": "device_storage.DeviceResourceStorage",
        "EntityAccessor": "entity.EntityAccessor",
        "Replacer": "host_storage.Replacer",
        "BitPool": "pool.BitPool",
    }
    for name, qualified in legacy.items():
        target = symbols[f"larecs.{qualified}"]["target"]
        if "#" in target:
            continue
        page = content / (target.rstrip("/") + ".md")
        text = page.read_text()
        # Hugo aliases keep incoming fragments because the browser retains them.
        text = text.replace("type: docs\n", f'type: docs\naliases: ["/larecs/{name}/"]\n', 1)
        page.write_text(text)

    data = {
        "revision": revision,
        "version": tomllib.loads((root / "pixi.toml").read_text())["workspace"]["version"],
        "symbols": symbols,
        "exports": exports,
    }
    destination = root / "docs/site/data/api.json"
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text(json.dumps(data, indent=2) + "\n")
    return data


if __name__ == "__main__":
    build_reference()
