"""Sync completed Roadmap issues against published release tags."""

import argparse
import json
import os
import re
import subprocess
from collections.abc import Callable, Iterable, Iterator
from functools import cache

from release_pr import TAG, output
from sync_stacked_issue_links import gh, graphql, referenced_issues, set_project_status


STACKED_CLOSE = re.compile(r"Closed by #(\d+), merged into `[^`]+`\.")
ISSUE_HISTORY = """
query($id: ID!, $cursor: String) {
  node(id: $id) {
    ... on Issue {
      state
      stateReason
      timelineItems(first: 100, after: $cursor, itemTypes: [
        CLOSED_EVENT, REOPENED_EVENT, CROSS_REFERENCED_EVENT, ISSUE_COMMENT
      ]) {
        pageInfo { hasNextPage endCursor }
        nodes {
          __typename
          ... on ClosedEvent {
            actor { login }
            closer {
              ... on Commit { oid }
              ... on PullRequest { mergeCommit { oid } }
            }
          }
          ... on ReopenedEvent { createdAt }
          ... on IssueComment { author { login } body }
          ... on CrossReferencedEvent {
            source {
              ... on PullRequest {
                body mergedAt repository { nameWithOwner } mergeCommit { oid }
              }
            }
          }
        }
      }
    }
  }
}
"""


def pages(
    query: str, connection: Callable[[dict], dict], token: str | None = None,
    **variables: str,
) -> Iterator[dict]:
    """Yield the nodes of a paginated GraphQL connection."""
    while True:
        page = connection(graphql(query, token=token, **variables))
        yield from page["nodes"]
        if not page["pageInfo"]["hasNextPage"]:
            break
        variables["cursor"] = page["pageInfo"]["endCursor"]


@cache
def merged_commit(repo: str, number: int) -> str | None:
    """Return the merge commit of a stacked pull request."""
    owner, name = repo.split("/")
    pr = graphql(
        """query($owner: String!, $name: String!, $number: Int!) {
          repository(owner: $owner, name: $name) {
            pullRequest(number: $number) { mergeCommit { oid } }
          }
        }""",
        owner=owner,
        name=name,
        number=number,
    )["repository"]["pullRequest"]
    return ((pr or {}).get("mergeCommit") or {}).get("oid")


def closing_commits(repo: str, number: int, events: Iterable[dict]) -> set[str]:
    """Find commits that closed the issue or carried its fix into a release.

    A stacked close records its PR in a bot comment. An integration PR can
    also name the issue with a closing keyword after squashing the original
    fix, so the original merge commit need not reach the release tag.
    """
    integration_merges = {}
    reopened_at = None
    closer = None
    stacked_pr = None
    for event in events:
        kind = event["__typename"]
        if kind == "ReopenedEvent":
            reopened_at = event["createdAt"]
            closer = None
            stacked_pr = None
        elif kind == "ClosedEvent":
            source = event["closer"] or {}
            closer = source.get("oid") or (source.get("mergeCommit") or {}).get("oid")
            if not closer and stacked_pr and (event["actor"] or {}).get("login") == "github-actions":
                closer = merged_commit(repo, stacked_pr)
            stacked_pr = None
        elif kind == "IssueComment" and (event["author"] or {}).get("login") == "github-actions":
            match = STACKED_CLOSE.fullmatch(event["body"])
            if match:
                stacked_pr = int(match[1])
        elif kind == "CrossReferencedEvent":
            source = event["source"] or {}
            if (
                source.get("repository", {}).get("nameWithOwner") == repo
                and source.get("mergedAt")
                and source.get("mergeCommit")
                and number in referenced_issues(source["body"])
            ):
                integration_merges[source["mergeCommit"]["oid"]] = source["mergedAt"]
    # A PR can reference the issue before it reopens and ship the replacement
    # fix afterward. Its merge time determines which closure it can support.
    commits = {
        commit
        for commit, merged_at in integration_merges.items()
        if reopened_at is None or merged_at >= reopened_at
    }
    if closer:
        commits.add(closer)
    return commits


def issue_history(data: dict) -> dict:
    """Return the timeline page if the issue is still closed as completed."""
    issue = data["node"]
    if issue["state"] == "CLOSED" and issue["stateReason"] == "COMPLETED":
        return issue["timelineItems"]
    return {"nodes": [], "pageInfo": {"hasNextPage": False}}


def released_commits(repo: str) -> set[str]:
    """Return commits reachable from published Larecs release tags, including betas."""
    releases = json.loads(gh("api", "--paginate", "--slurp", f"repos/{repo}/releases"))
    tags = [
        f"refs/tags/{release['tag_name']}"
        for page in releases
        for release in page
        if not release["draft"] and TAG.fullmatch(release["tag_name"])
    ]
    return set(output("git", "rev-list", *tags, "--").splitlines()) if tags else set()


def sync(repo: str, token: str | None, dry_run: bool) -> None:
    """Update existing, completed issues in the Larecs Releases project."""
    owner = repo.split("/")[0]
    project = graphql(
        """query($owner: String!) {
          organization(login: $owner) { projectV2(number: 1) {
            id field(name: "Status") {
              ... on ProjectV2SingleSelectField { id options { id name } }
            }
          } }
        }""",
        token=token,
        owner=owner,
    )["organization"]["projectV2"]
    field = project["field"]
    options = {entry["name"]: entry["id"] for entry in field["options"]}
    available = released_commits(repo)
    for item in pages(
        """query($id: ID!, $cursor: String) {
          node(id: $id) { ... on ProjectV2 {
            items(first: 100, after: $cursor) {
              pageInfo { hasNextPage endCursor }
              nodes {
                id isArchived
                fieldValueByName(name: "Status") {
                  ... on ProjectV2ItemFieldSingleSelectValue { name }
                }
                content {
                  ... on Issue {
                    id number state stateReason repository { nameWithOwner }
                  }
                }
              }
            }
          } }
        }""",
        lambda data: data["node"]["items"],
        token=token,
        id=project["id"],
    ):
        issue = item["content"] or {}
        if (
            item["isArchived"]
            or issue.get("state") != "CLOSED"
            or issue.get("stateReason") != "COMPLETED"
            or issue["repository"]["nameWithOwner"] != repo
        ):
            continue
        number = issue["number"]
        events = list(pages(ISSUE_HISTORY, issue_history, id=issue["id"]))
        if not events:
            continue
        status = "Done" if closing_commits(repo, number, events) & available else "In review"
        current = (item["fieldValueByName"] or {}).get("name")
        if current == status:
            continue
        print(f"#{number}: {current!r} -> {status!r}", flush=True)
        if not dry_run:
            set_project_status(project["id"], item["id"], field["id"], options[status], token)


def main() -> None:
    """Read the repository and run the Roadmap status sync."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", default=os.environ.get("GITHUB_REPOSITORY"))
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()
    if not args.repo:
        parser.error("pass --repo or set GITHUB_REPOSITORY")
    try:
        sync(args.repo, os.environ.get("PROJECT_TOKEN") or None, args.dry_run)
    except subprocess.CalledProcessError as error:
        if error.stderr:
            parser.exit(1, error.stderr)
        raise


if __name__ == "__main__":
    main()
