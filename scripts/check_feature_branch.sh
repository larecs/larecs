#!/usr/bin/env bash
# Reject integration history from current and archived nightly builds.
set -euo pipefail

remote="${NIGHTLY_REMOTE:-origin}"
nightly_only="$(
    while read -r ref; do
        git rev-list --first-parent "$ref" "^$remote/main"
    done < <(git for-each-ref --format='%(refname)' \
        "refs/remotes/$remote/nightly" "refs/remotes/$remote/nightly-history/")
)"
branch="$(git rev-list HEAD "^$remote/main")"
found="$(comm -12 <(sort <<<"${nightly_only}") <(sort <<<"${branch}") | sed '/^$/d')"
if [[ -n "${found}" ]]; then
    echo "::error::This branch contains commits that exist only on nightly. Start feature branches from main and never merge nightly into them."
    while read -r sha; do git log -1 --format='  %h %s' "${sha}"; done <<<"${found}"
    exit 1
fi
echo "No nightly-only commits."
