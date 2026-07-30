import argparse
import asyncio
from pathlib import Path


async def build_static_site(hugo_site_dir):
    larecs_dir = Path(__file__).parent.parent
    return await asyncio.create_subprocess_exec(
        "hugo",
        "-s",
        hugo_site_dir,
        cwd=larecs_dir,
    )


async def build_docs(watch=False):
    larecs_dir = Path(__file__).parent.parent

    args = ["build"]
    if watch:
        args.append("--watch")

    return await asyncio.create_subprocess_exec(
        "modo",
        *args,
        cwd=larecs_dir,
    )


async def serve_docs(hugo_site_dir):
    larecs_dir = Path(__file__).parent.parent
    return await asyncio.create_subprocess_exec(
        "hugo", "server", cwd=larecs_dir / hugo_site_dir
    )


async def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=["build", "serve", "watch"], default="build")
    args = parser.parse_args()

    match args.command:
        case "build":
            modo_proc = await build_docs()
            await modo_proc.wait()

            hugo_proc = await build_static_site("docs/site")
            await hugo_proc.wait()

        case "watch":
            modo_proc = await build_docs(watch=True)
            hugo_proc = await serve_docs("docs/site")

            await asyncio.gather(
                modo_proc.wait(),
                hugo_proc.wait(),
            )

        case "serve":
            hugo_proc = await serve_docs("docs/site")
            await hugo_proc.wait()


if __name__ == "__main__":
    asyncio.run(main())
