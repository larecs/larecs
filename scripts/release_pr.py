"""Open and verify stable release pull requests."""

import argparse
import json
import os
import re
import subprocess
import sys
from pathlib import Path


TAG = re.compile(r"v[0-9]+\.[0-9]+\.[0-9]+(?:b[0-9]+)?")
REPO_API = "repos/{owner}/{repo}"
REVIEW_STATES = {"APPROVED", "CHANGES_REQUESTED", "DISMISSED"}
WRITE_PERMISSIONS = {"admin", "maintain", "write"}


def output(*command: str) -> str:
    """Run a command and collect its standard output.

    Args:
        command: Executable and its arguments.

    Raises:
        OSError: If the executable cannot be started.
        subprocess.CalledProcessError: If the command fails.

    Returns:
        The command's output with trailing whitespace removed.
    """
    return subprocess.check_output(command, text=True).rstrip()


def previous_tag() -> str:
    """Find the most recent published release, including beta releases.

    Raises:
        SystemExit: If no release has been published.
        subprocess.CalledProcessError: If GitHub cannot list releases.

    Returns:
        The previous release's Git tag.
    """
    releases = json.loads(
        output("gh", "release", "list", "--exclude-drafts", "--limit", "1", "--json", "tagName")
    )
    if not releases:
        sys.exit("No previous release is available.")
    return releases[0]["tagName"]


def preview_section(branch: str) -> str:
    """Render the Pixi instructions for a release candidate.

    Args:
        branch: Release candidate branch name.

    Returns:
        The Markdown section for the release PR description.
    """
    return f'''## Try the release candidate

Add the preview setting and these channels to your existing `[workspace]` table in `pixi.toml`.

```toml
[workspace]
preview = ["pixi-build"]
channels = [
    "conda-forge",
    "https://repo.prefix.dev/max",
    "https://prefix.dev/tree-d",
]
```

```sh
pixi add --git https://github.com/larecs/larecs.git \\
  --branch {branch} larecs
```'''


def require_preview_section(body: str, branch: str) -> None:
    """Require the release candidate instructions as the first section.

    Args:
        body: Release PR description in Markdown.
        branch: Release candidate branch name.

    Raises:
        SystemExit: If the section is missing, misplaced, or points to another branch.
    """
    expected = preview_section(branch)
    description = "\n".join(body.splitlines()).strip()
    intro, *sections = re.split(r"(?m)^(?=## )", description, maxsplit=2)
    if not intro.strip() or not sections or sections[0].strip() != expected:
        sys.exit(f"Place this section after the opening description:\n\n{expected}")


def open_release(tag: str, ref: str) -> None:
    """Open a release pull request for a commit on main.

    Args:
        tag: New release tag in vX.Y.Z or vX.Y.ZbN format.
        ref: Commit or ref to release.

    Raises:
        SystemExit: If the tag is invalid, already exists, or has no new changes.
        subprocess.CalledProcessError: If Git or GitHub rejects the operation.
    """
    if not TAG.fullmatch(tag):
        sys.exit("Use a tag in vX.Y.Z or vX.Y.ZbN format.")

    subprocess.run(["git", "fetch", "origin", "main", "--tags"], check=True)
    previous = previous_tag()
    base = output("git", "rev-parse", f"refs/tags/{previous}^{{commit}}")
    candidate = output(
        "git", "rev-parse", "--verify", "--end-of-options", f"{ref}^{{commit}}"
    )
    subprocess.run(["git", "merge-base", "--is-ancestor", base, candidate], check=True)
    subprocess.run(["git", "merge-base", "--is-ancestor", candidate, "origin/main"], check=True)
    if base == candidate or output("git", "tag", "--list", tag):
        sys.exit(f"Choose a new release tag and a commit after {previous}.")

    notes = output(
        "gh", "api", f"{REPO_API}/releases/generate-notes",
        "-f", f"tag_name={tag}", "-f", f"target_commitish={candidate}",
        "-f", f"previous_tag_name={previous}", "--jq", ".body",
    )
    base_branch = f"release/base-{tag}"
    candidate_branch = f"release/candidate-{tag}"
    description = (
        f"Review the Larecs `{tag}` release candidate and the changes since `{previous}`.\n\n"
        f"{preview_section(candidate_branch)}\n\n{notes}"
    )
    subprocess.run(
        ["git", "push", "--atomic", "origin",
         f"{base}:refs/heads/{base_branch}", f"{candidate}:refs/heads/{candidate_branch}"],
        check=True,
    )
    subprocess.run(
        ["gh", "pr", "create", "--base", base_branch, "--head", candidate_branch,
         "--title", f"Release Larecs {tag}", "--body", description],
        check=True,
    )


def check_description(number: int) -> None:
    """Verify the description on an open release PR.

    Args:
        number: Release pull request number.

    Raises:
        SystemExit: If the PR number or description is invalid.
        subprocess.CalledProcessError: If GitHub cannot read the PR.
    """
    if number < 1:
        sys.exit("Specify a release PR number.")
    pr = json.loads(output("gh", "pr", "view", str(number), "--json", "body,headRefName"))
    require_preview_section(pr["body"] or "", pr["headRefName"])


def has_approval(number: int, author: str, candidate: str, merged_at: str) -> bool:
    """Check for approval of the exact candidate by an eligible reviewer.

    Args:
        number: Release pull request number.
        author: Pull request author's GitHub login.
        candidate: Commit SHA to release.
        merged_at: GitHub timestamp of the merge, in UTC.

    Raises:
        subprocess.CalledProcessError: If GitHub cannot verify reviews or access.

    Returns:
        Whether a human with write access approved the candidate before the merge.
    """
    pages = json.loads(
        output("gh", "api", "--paginate", "--slurp", f"{REPO_API}/pulls/{number}/reviews")
    )
    latest = {}
    # GitHub lists reviews in chronological order across pages.
    for page in pages:
        for review in page:
            user = review["user"]
            submitted_at = review["submitted_at"]
            if (
                user and user["type"] == "User" and user["login"] != author
                and submitted_at and submitted_at <= merged_at
                and review["state"] in REVIEW_STATES
            ):
                latest[user["login"]] = review
    for login, review in latest.items():
        if review["state"] == "APPROVED" and review["commit_id"] == candidate:
            permission = output(
                "gh", "api", f"{REPO_API}/collaborators/{login}/permission", "--jq", ".permission"
            )
            if permission in WRITE_PERMISSIONS:
                return True
    return False


def resolve_release(number: int) -> None:
    """Verify a merged release PR and write the candidate to GitHub Actions outputs.

    Args:
        number: Release pull request number.

    Raises:
        SystemExit: If the PR, description, release range, or candidate approval is invalid.
        subprocess.CalledProcessError: If Git or GitHub cannot verify the candidate.
        OSError: If the GitHub Actions output file cannot be written.
    """
    if number < 1:
        sys.exit("Specify a release PR number.")

    pr = json.loads(output(
        "gh", "pr", "view", str(number), "--json",
        "author,baseRefName,body,headRefName,headRefOid,isCrossRepository,mergeCommit,mergedAt,state",
    ))
    base_branch = pr["baseRefName"]
    tag = base_branch.removeprefix("release/base-")
    if (
        pr["state"] != "MERGED" or pr["isCrossRepository"] or not TAG.fullmatch(tag)
        or base_branch != f"release/base-{tag}" or pr["headRefName"] != f"release/candidate-{tag}"
    ):
        sys.exit(f"PR #{number} must be a merged release PR from this repository.")

    require_preview_section(pr["body"] or "", pr["headRefName"])

    previous = previous_tag()
    base = output("git", "rev-parse", f"refs/tags/{previous}^{{commit}}")
    candidate = pr["headRefOid"]
    merge = pr["mergeCommit"]["oid"]
    if output("git", "rev-list", "--parents", "-n", "1", merge).split() != [merge, base, candidate]:
        sys.exit(
            f"The release PR must use a merge commit and start at the latest published tag ({previous})."
        )
    if output("git", "diff", "--name-only", candidate, merge):
        sys.exit("The merged tree must match the reviewed candidate.")
    subprocess.run(["git", "merge-base", "--is-ancestor", candidate, "origin/main"], check=True)
    if output("git", "tag", "--list", tag):
        sys.exit(f"Release tag {tag} already exists.")

    if not has_approval(number, pr["author"]["login"], candidate, pr["mergedAt"]):
        sys.exit(
            f"PR #{number} needs a pre-merge approval of {candidate} by a reviewer with write access."
        )

    with Path(os.environ["GITHUB_OUTPUT"]).open("a") as file:
        file.write(f"sha={candidate}\ntag={tag}\nversion={tag[1:]}\nprevious={previous}\n")


def main() -> None:
    """Run the requested release command and report failures to the caller.

    Raises:
        SystemExit: If arguments are invalid or a release command fails.
    """
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    open_command = commands.add_parser("open", help="open a release PR for a commit on main")
    open_command.add_argument("tag")
    open_command.add_argument("ref", nargs="?", default="origin/main")
    description_command = commands.add_parser(
        "check-description", help="verify the Pixi instructions in a release PR"
    )
    description_command.add_argument("number", type=int)
    resolve_command = commands.add_parser("resolve", help="verify a merged release PR for publishing")
    resolve_command.add_argument("number", type=int)
    args = parser.parse_args()
    try:
        if args.command == "open":
            open_release(args.tag, args.ref)
        elif args.command == "check-description":
            check_description(args.number)
        else:
            resolve_release(args.number)
    except (OSError, subprocess.CalledProcessError, json.JSONDecodeError) as error:
        sys.exit(str(error))


if __name__ == "__main__":
    main()
