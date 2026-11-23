#!/usr/bin/env bash
set -euo pipefail

pr=$1
if [[ ! "$pr" =~ ^[1-9][0-9]*$ ]]; then
  echo "Specify a release PR number." >&2
  exit 1
fi

# A merge commit records the exact base and candidate that GitHub merged.
details=$(gh pr view "$pr" --json author,baseRefName,headRefName,headRefOid,isCrossRepository,mergeCommit,mergedAt,state \
  --jq 'select(.state == "MERGED" and (.isCrossRepository | not)) |
        [.baseRefName, .headRefName, .headRefOid, .mergeCommit.oid, .author.login, .mergedAt] | @tsv')
read -r base_branch candidate_branch candidate merge_commit author merged_at <<< "$details"
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

# Verify approval independently of the branch rules that allowed the merge.
reviewers=$(gh api --paginate --slurp "repos/{owner}/{repo}/pulls/$pr/reviews" |
  jq -r --arg candidate "$candidate" --arg author "$author" --arg merged_at "$merged_at" '
    add
    | map(select(.user.type == "User" and .user.login != $author
        and .submitted_at != null and .submitted_at <= $merged_at
        and (.state == "APPROVED" or .state == "CHANGES_REQUESTED" or .state == "DISMISSED")))
    | group_by(.user.id)[]
    | max_by(.submitted_at, .id)
    | select(.state == "APPROVED" and .commit_id == $candidate)
    | .user.login')
approved_by=
while IFS= read -r reviewer; do
  [[ -n "$reviewer" ]] || continue
  permission=$(gh api "repos/{owner}/{repo}/collaborators/$reviewer/permission" --jq .permission)
  case "$permission" in
    write|maintain|admin) approved_by=$reviewer; break ;;
  esac
done <<< "$reviewers"
if [[ -z "$approved_by" ]]; then
  echo "PR #$pr needs a pre-merge approval of $candidate by a reviewer with write access." >&2
  exit 1
fi

{
  echo "sha=$candidate"
  echo "tag=$tag"
  echo "version=${tag#v}"
  echo "previous=$previous"
} >> "$GITHUB_OUTPUT"
