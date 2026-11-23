#!/usr/bin/env bash
set -euo pipefail

tag=${1:-}
if [[ ! "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(b[0-9]+)?$ ]] || (( $# > 2 )); then
  echo "Usage: $0 <vX.Y.Z or vX.Y.ZbN> [main commit]" >&2
  exit 1
fi

git fetch origin main --tags
previous=$(gh release list --exclude-drafts --limit 1 --json tagName --jq '.[0].tagName')
base=$(git rev-parse "refs/tags/$previous^{commit}")
candidate=$(git rev-parse --verify "${2:-origin/main}^{commit}")
git merge-base --is-ancestor "$base" "$candidate"
git merge-base --is-ancestor "$candidate" origin/main
if [[ "$base" == "$candidate" ]] || git show-ref --verify --quiet "refs/tags/$tag"; then
  echo "Choose a new release tag and a commit after $previous." >&2
  exit 1
fi

git push --atomic origin \
  "$base:refs/heads/release/base-$tag" \
  "$candidate:refs/heads/release/candidate-$tag"

notes=$(gh api "repos/{owner}/{repo}/releases/generate-notes" \
  -f tag_name="$tag" -f target_commitish="$candidate" \
  -f previous_tag_name="$previous" --jq .body)
gh pr create --base "release/base-$tag" --head "release/candidate-$tag" \
  --title "Release Larecs $tag" --body "$notes"
