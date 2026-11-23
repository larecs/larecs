#!/usr/bin/env bash
set -euo pipefail

pr=$1
if [[ ! "$pr" =~ ^[1-9][0-9]*$ ]]; then
  echo "Specify a release PR number." >&2
  exit 1
fi

# A merge commit records the exact base and candidate that GitHub merged.
details=$(gh pr view "$pr" --json baseRefName,headRefName,headRefOid,isCrossRepository,mergeCommit,state \
  --jq 'select(.state == "MERGED" and (.isCrossRepository | not)) |
        [.baseRefName, .headRefName, .headRefOid, .mergeCommit.oid] | @tsv')
read -r base_branch candidate_branch candidate merge_commit <<< "$details"
tag=${base_branch#release/base-}
if [[ ! "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(b[0-9]+)?$ ]] ||
   [[ "$base_branch" != "release/base-$tag" || "$candidate_branch" != "release/candidate-$tag" ]]; then
  echo "PR #$pr must be a merged release PR from this repository." >&2
  exit 1
fi

previous=$(gh release list --exclude-drafts --limit 1 --json tagName --jq '.[0].tagName')
read -r _ base head extra <<< "$(git rev-list --parents -n 1 "$merge_commit")"
if [[ "$head" != "$candidate" || -n "$extra" ||
      "$base" != "$(git rev-parse "refs/tags/$previous^{commit}")" ]]; then
  echo "The release PR must use a merge commit and start at the latest stable tag ($previous)." >&2
  exit 1
fi
if [[ -n $(git diff --name-only "$candidate" "$merge_commit") ]]; then
  echo "The merged tree must match the reviewed candidate." >&2
  exit 1
fi
git merge-base --is-ancestor "$candidate" origin/main
if git show-ref --verify --quiet "refs/tags/$tag"; then
  echo "Release tag $tag already exists." >&2
  exit 1
fi

{
  echo "sha=$candidate"
  echo "tag=$tag"
  echo "version=${tag#v}"
  echo "previous=$previous"
} >> "$GITHUB_OUTPUT"
