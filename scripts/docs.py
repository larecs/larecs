import argparse
import asyncio
import json
import platform
import shutil
import subprocess
import sys
from email.message import Message
from os import environ
from pathlib import Path, PurePosixPath
from tempfile import TemporaryDirectory
from urllib.error import URLError
from urllib.parse import urlparse
from urllib.request import urlopen


def modo_url(modo_version: str) -> str:
    """
    Returns the URL for the Modo release with the given version for the current platform.

    Args:
        modo_version (str): The version of Modo to download.

    Returns:
        str: The URL for the Modo release.
    """
    match platform.machine().lower():
        case "x86_64" | "amd64":
            arch = "amd64"
        case "aarch64" | "arm64":
            arch = "arm64"
        case arch:
            sys.exit(f"Unsupported architecture: {arch}")
    match platform.system():
        case "Linux":
            os_name = "linux"
        case "Darwin":
            os_name = "macos"
        case "Windows":
            os_name = "windows"
            if arch != "amd64":
                sys.exit(
                    f"Unsupported OS architecture combination: {os_name}-{platform.machine()}"
                )
        case os_name:
            sys.exit(f"Unsupported OS: {os_name}")

    return f"https://github.com/mlange-42/modo/releases/download/{modo_version}/modo-{modo_version}-{os_name}-{arch}.tar.gz"


def hugo_url(hugo_version: str) -> str:
    """
    Returns the URL for the Hugo release with the given version for the current platform.

    Args:
        hugo_version (str): The version of Hugo to download.

    Returns:
        str: The URL for the Hugo release.
    """
    match platform.machine().lower():
        case "x86_64" | "amd64":
            arch = "amd64"
        case "aarch64" | "arm64":
            arch = "arm64"
        case arch:
            sys.exit(f"Unsupported architecture: {arch}")
    match platform.system():
        case "Linux":
            os_name = "linux"
            ext = "tar.gz"
        case "Darwin":
            os_name = "darwin"
            arch = "universal"
            ext = "pkg"
            sys.exit("MacOS is currently not supported")
        case "Windows":
            os_name = "windows"
            ext = "zip"
            if arch != "amd64":
                sys.exit(
                    f"Unsupported OS architecture combination: {os_name}-{platform.machine()}"
                )
        case os_name:
            sys.exit(f"Unsupported OS: {os_name}")

    return f"https://github.com/gohugoio/hugo/releases/download/v{hugo_version}/hugo_extended_{hugo_version}_{os_name}-{arch}.{ext}"


def get_latest_modo_version(fallback: str = "") -> str:
    try:
        with urlopen(
            "https://api.github.com/repos/mlange-42/modo/releases/latest"
        ) as response:
            release = json.load(response)
        return release["tag_name"]
    except (URLError, KeyError, json.JSONDecodeError):
        return fallback


def get_filename(url: str, response, fallback: str = "modo.tar.gz") -> str:
    """
    Returns the filename for the given URL and response.
    """
    # 1. Content-Disposition
    content_disposition = response.headers.get("Content-Disposition")
    if content_disposition:
        headers = Message()
        headers["Content-Disposition"] = content_disposition

        if filename := headers.get_filename():
            return filename

    # 2. URL path
    if filename := PurePosixPath(urlparse(url).path).name:
        return filename

    # 3. Fallback
    return fallback


class BinDir:
    _path: Path

    def __init__(self):
        script_dir = Path(__file__).parent
        self._path = (script_dir / ".." / ".doc_install_cache").absolute().resolve()
        self._path.mkdir(parents=True, exist_ok=True)

    def modo(self):
        return self._path / "modo"

    def hugo(self):
        return self._path / "hugo"

    def install_modo(self, modo_version):
        """
        Downloads and extracts the Modo binary.

        Args:
            modo_version (str): The version of Modo to download.
        """
        url = modo_url(modo_version)

        with TemporaryDirectory() as tmp:
            tmp_dir = Path(tmp)

            with urlopen(url) as response:
                filename = get_filename(url, response)
                destination = tmp_dir / Path(filename)

                with destination.open("wb") as file:
                    while chunk := response.read(1024 * 1024):
                        file.write(chunk)

            shutil.unpack_archive(destination, self._path)

    def install_hugo(self, hugo_version):
        """
        Downloads and extracts the Hugo binary.

        Args:
            hugo_version (str): The version of Hugo to download.
        """
        url = hugo_url(hugo_version)

        with TemporaryDirectory() as tmp:
            tmp_dir = Path(tmp)

            with urlopen(url) as response:
                filename = get_filename(url, response)
                destination = tmp_dir / Path(filename)

                with destination.open("wb") as file:
                    while chunk := response.read(1024 * 1024):
                        file.write(chunk)

            shutil.unpack_archive(destination, self._path)


async def build_static_site(bin_dir: BinDir, hugo_site_dir):
    larecs_dir = Path(__file__).parent.parent
    return asyncio.create_subprocess_exec(
        bin_dir.hugo(),
        "-s",
        cwd=larecs_dir / hugo_site_dir,
    )


def build_docs(bin_dir: BinDir, watch=False):
    larecs_dir = Path(__file__).parent.parent
    return asyncio.create_subprocess_exec(
        bin_dir.modo(),
        "build",
        "--watch" if watch else "",
        cwd=larecs_dir,
    )


def serve_docs(bin_dir: BinDir, hugo_site_dir):
    larecs_dir = Path(__file__).parent.parent
    return asyncio.create_subprocess_exec(
        bin_dir.hugo(), "server", cwd=larecs_dir / hugo_site_dir
    )


def parse_modo_version(args) -> str:
    modo_version = args.modo_version
    if not modo_version or not modo_version.strip():
        sys.exit(
            'Modo version not provided as an argument or via the MODO_VERSION environment variable. Specify "latest" or a specific version tag!'
        )
    if modo_version == "latest":
        modo_version = get_latest_modo_version()
    return modo_version


def parse_hugo_version(args):
    hugo_version = args.hugo_version
    if not hugo_version or not hugo_version.strip():
        sys.exit(
            "Hugo version not provided as an argument or via the HUGO_VERSION environment variable. Specify a version tag!"
        )
    return hugo_version


async def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=["build", "serve", "watch"], default="build")
    parser.add_argument("--modo-version", default=environ.get("MODO_VERSION"))
    parser.add_argument("--hugo-version", default=environ.get("HUGO_VERSION"))
    args = parser.parse_args()

    bin_dir = BinDir()

    match args.command:
        case "build":
            bin_dir.install_modo(parse_modo_version(args))
            bin_dir.install_hugo(parse_hugo_version(args))
            await build_docs(bin_dir)
            await build_static_site(bin_dir, "docs/site")

        case "watch":
            bin_dir.install_modo(parse_modo_version(args))
            bin_dir.install_hugo(parse_hugo_version(args))

            modo_proc = build_docs(bin_dir, watch=True)
            hugo_proc = serve_docs(bin_dir, "docs/site")

            await asyncio.gather(
                modo_proc,
                hugo_proc,
            )

        case "serve":
            await serve_docs(bin_dir, "docs/site")


if __name__ == "__main__":
    asyncio.run(main())
