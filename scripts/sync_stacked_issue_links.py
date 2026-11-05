"""Applies closing keywords of stacked pull requests to their issues.

GitHub links `Closes #N` only for pull requests into the default branch. For a
stacked pull request, this script does what the link would do:

- While the pull request is open, it moves each referenced open issue in the
  project to "In progress" if the issue is still in an earlier status.
- When the pull request is merged, it closes each referenced open issue.
  An issue reopened after an earlier automatic close stays open, unless the
  pull request was edited after the reopen and still references it.

It uses the `gh` CLI. `GH_TOKEN` needs issue write access; `PROJECT_TOKEN`, if
set, is used for the project and needs organization project write access.
"""

import argparse
import json
import os
import re
import subprocess
import sys
from datetime import datetime, timedelta, timezone

CLOSING_KEYWORD_RE = re.compile(
    r"\b(?:close[sd]?|fix(?:e[sd])?|resolve[sd]?)\s*:?\s+#(\d+)\b", re.IGNORECASE
)


def gh(*args: str, token: str | None = None) -> str:
    """Runs a `gh` command and returns its standard output.

    Args:
        *args: Arguments passed to `gh`.
        token: Token to use instead of the ambient `GH_TOKEN`.

    Returns:
        The command's standard output.

    Raises:
        subprocess.CalledProcessError: If the command fails.
    """
    env = os.environ | ({"GH_TOKEN": token} if token else {})
    result = subprocess.run(
        ["gh", *args], env=env, check=True, capture_output=True, text=True
    )
    return result.stdout


def graphql(query: str, token: str | None = None, **variables: str | int) -> dict:
    """Runs a GraphQL query through `gh api graphql`.

    Args:
        query: The GraphQL document.
        token: Token to use instead of the ambient `GH_TOKEN`.
        **variables: Variables of the query; integers are sent as numbers.

    Returns:
        The `data` object of the response.
    """
    args = ["api", "graphql", "-f", f"query={query}"]
    for name, value in variables.items():
        flag = "-F" if isinstance(value, int) else "-f"
        args += [flag, f"{name}={value}"]
    return json.loads(gh(*args, token=token))["data"]


def referenced_issues(body: str | None) -> list[int]:
    """Returns the issue numbers named by closing keywords, in order.

    Args:
        body: The pull request body.

    Returns:
        Unique issue numbers in this repository.
    """
    numbers = [int(match) for match in CLOSING_KEYWORD_RE.findall(body or "")]
    return list(dict.fromkeys(numbers))


class Project:
    """Status updates for one organization project."""

    def __init__(
        self,
        owner: str,
        number: int,
        field: str,
        target: str,
        movable: list[str],
        token: str | None,
    ):
        """Looks up the project, its status field, and the target option.

        Args:
            owner: Organization that owns the project.
            number: Project number.
            field: Name of the single-select status field.
            target: Status option to set.
            movable: Statuses that may be replaced; an empty status always may.
            token: Token with project access.
        """
        self.token = token
        self.movable = set(movable)
        self.target = target
        data = self._lookup(owner, number, field)
        project = data["organization"]["projectV2"]
        self.id = project["id"]
        self.field_id = project["field"]["id"]
        options = {option["name"]: option["id"] for option in project["field"]["options"]}
        if target not in options:
            raise SystemExit(f"error: project status {target!r} does not exist")
        self.option_id = options[target]

    def _lookup(self, owner: str, number: int, field: str) -> dict:
        """Queries the project and its status field.

        Args:
            owner: Organization that owns the project.
            number: Project number.
            field: Name of the status field.

        Returns:
            The GraphQL `data` object.
        """
        args = [
            "api",
            "graphql",
            "-f",
            """query=query($owner: String!, $number: Int!, $field: String!) {
              organization(login: $owner) { projectV2(number: $number) {
                id
                field(name: $field) {
                  ... on ProjectV2SingleSelectField { id options { id name } }
                }
              } }
            }""",
            "-f",
            f"owner={owner}",
            "-F",
            f"number={number}",
            "-f",
            f"field={field}",
        ]
        return json.loads(gh(*args, token=self.token))["data"]

    def mark(self, issue_id: str, number: int, dry_run: bool) -> None:
        """Moves an issue to the target status if its status may be replaced.

        Adds the issue to the project first when it is missing.

        Args:
            issue_id: GraphQL node ID of the issue.
            number: Issue number, for messages.
            dry_run: Report the change without making it.
        """
        data = graphql(
            """query($id: ID!) { node(id: $id) { ... on Issue {
              projectItems(first: 20) { nodes {
                id project { id }
                fieldValueByName(name: "Status") {
                  ... on ProjectV2ItemFieldSingleSelectValue { name }
                }
              } }
            } } }""",
            token=self.token,
            id=issue_id,
        )
        items = [
            item
            for item in data["node"]["projectItems"]["nodes"]
            if item["project"]["id"] == self.id
        ]
        status = (items[0]["fieldValueByName"] or {}).get("name") if items else None
        if status is not None and status not in self.movable:
            print(f"#{number}: status {status!r} kept")
            return
        print(f"#{number}: status {status!r} -> {self.target!r}")
        if dry_run:
            return
        if items:
            item_id = items[0]["id"]
        else:
            item_id = graphql(
                """mutation($project: ID!, $content: ID!) {
                  addProjectV2ItemById(input: {projectId: $project, contentId: $content}) {
                    item { id }
                  }
                }""",
                token=self.token,
                project=self.id,
                content=issue_id,
            )["addProjectV2ItemById"]["item"]["id"]
        graphql(
            """mutation($project: ID!, $item: ID!, $field: ID!, $option: String!) {
              updateProjectV2ItemFieldValue(input: {
                projectId: $project, itemId: $item, fieldId: $field,
                value: {singleSelectOptionId: $option}
              }) { projectV2Item { id } }
            }""",
            token=self.token,
            project=self.id,
            item=item_id,
            field=self.field_id,
            option=self.option_id,
        )


def issue(repo: str, number: int) -> dict | None:
    """Returns an issue's node ID and state, or None for pull requests.

    Args:
        repo: Repository as `owner/name`.
        number: Issue number.

    Returns:
        The issue fields, or None when the number is not an issue.
    """
    data = json.loads(gh("api", f"repos/{repo}/issues/{number}"))
    if "pull_request" in data:
        return None
    return {"id": data["node_id"], "state": data["state"]}


def reopened_after_automatic_close(repo: str, number: int, bot: str) -> str | None:
    """Returns when an issue was reopened after its last automatic close.

    Args:
        repo: Repository as `owner/name`.
        number: Issue number.
        bot: Login of the account that closes issues automatically.

    Returns:
        The time of the latest `reopened` event that follows the latest
        `closed` event by `bot`, or None if there is none.
    """
    events = json.loads(
        gh("api", "--paginate", "--slurp", f"repos/{repo}/issues/{number}/events")
    )
    last_close = None
    reopened_at = None
    for event in (event for page in events for event in page):
        if event["event"] == "closed" and (event.get("actor") or {}).get("login") == bot:
            last_close = event["created_at"]
            reopened_at = None
        elif event["event"] == "reopened" and last_close is not None:
            reopened_at = event["created_at"]
    return reopened_at


def last_edited(repo: str, number: int) -> str:
    """Returns when a pull request's title or body was last changed.

    Args:
        repo: Repository as `owner/name`.
        number: Pull request number.

    Returns:
        The last edit time, or the creation time if it was never edited.
    """
    owner, name = repo.split("/")
    pr = graphql(
        """query($owner: String!, $name: String!, $number: Int!) {
          repository(owner: $owner, name: $name) {
            pullRequest(number: $number) { createdAt lastEditedAt }
          }
        }""",
        owner=owner,
        name=name,
        number=number,
    )["repository"]["pullRequest"]
    return pr["lastEditedAt"] or pr["createdAt"]


def pull_requests(repo: str, number: int | None, lookback: timedelta) -> list[dict]:
    """Returns the pull requests to process.

    Args:
        repo: Repository as `owner/name`.
        number: A single pull request to process, or None for a full scan.
        lookback: For a full scan, how far back merged pull requests count.

    Returns:
        Pull requests with number, base branch, body, state, and fork flag.
    """
    fields = "number,baseRefName,body,state,isCrossRepository"
    if number is not None:
        return [json.loads(gh("pr", "view", str(number), "-R", repo, "--json", fields))]
    since = (datetime.now(timezone.utc) - lookback).strftime("%Y-%m-%dT%H:%M:%SZ")
    open_prs = json.loads(
        gh("pr", "list", "-R", repo, "--state", "open", "--limit", "200", "--json", fields)
    )
    merged_prs = json.loads(
        gh(
            "pr", "list", "-R", repo, "--state", "merged", "--limit", "200",
            "--search", f"merged:>={since}", "--json", fields,
        )
    )
    return open_prs + merged_prs


def main() -> None:
    """Parses arguments and syncs the selected pull requests."""
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--repo", default=os.environ.get("GITHUB_REPOSITORY"))
    parser.add_argument("--pr", type=int, help="process only this pull request")
    parser.add_argument("--lookback-hours", type=float, default=3.0)
    parser.add_argument("--project-owner", default="larecs")
    parser.add_argument("--project-number", type=int, default=1)
    parser.add_argument("--status-field", default="Status")
    parser.add_argument("--target-status", default="In progress")
    parser.add_argument("--movable-status", action="append", default=None)
    parser.add_argument(
        "--bot-login",
        default="github-actions[bot]",
        help="account whose closes count as automatic",
    )
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()
    if not args.repo:
        raise SystemExit("error: pass --repo or set GITHUB_REPOSITORY")

    default_branch = json.loads(gh("api", f"repos/{args.repo}"))["default_branch"]
    project_token = os.environ.get("PROJECT_TOKEN") or None
    project = None
    try:
        project = Project(
            args.project_owner,
            args.project_number,
            args.status_field,
            args.target_status,
            args.movable_status or ["Backlog", "Ready"],
            project_token,
        )
    except subprocess.CalledProcessError as error:
        print(
            "warning: project not accessible; set PROJECT_TOKEN to update statuses:"
            f" {error.stderr.strip()}",
            file=sys.stderr,
        )

    failed = False
    for pr in pull_requests(args.repo, args.pr, timedelta(hours=args.lookback_hours)):
        if pr["baseRefName"] == default_branch or pr["isCrossRepository"]:
            continue
        numbers = referenced_issues(pr["body"])
        if not numbers or pr["state"] == "CLOSED":
            continue
        print(f"PR #{pr['number']} ({pr['state'].lower()}, base {pr['baseRefName']})")
        for number in numbers:
            target = issue(args.repo, number)
            if target is None or target["state"] != "open":
                continue
            try:
                if pr["state"] == "MERGED":
                    # A reopen after an automatic close wins, unless the pull
                    # request was edited afterwards and still requests the close.
                    reopened_at = reopened_after_automatic_close(
                        args.repo, number, args.bot_login
                    )
                    if reopened_at and reopened_at > last_edited(args.repo, pr["number"]):
                        print(f"#{number}: reopened after an automatic close; kept open")
                        continue
                    print(f"#{number}: closing")
                    if not args.dry_run:
                        gh(
                            "issue", "close", str(number), "-R", args.repo,
                            "--reason", "completed", "--comment",
                            f"Closed by #{pr['number']}, merged into"
                            f" `{pr['baseRefName']}`.",
                        )
                elif project is not None:
                    project.mark(target["id"], number, args.dry_run)
            except subprocess.CalledProcessError as error:
                failed = True
                print(f"error: #{number}: {error.stderr.strip()}", file=sys.stderr)
    if failed:
        sys.exit(1)


if __name__ == "__main__":
    main()
