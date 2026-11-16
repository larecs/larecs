#!/usr/bin/env bash
# nightly.sh — Maintainer helpers for the nightly-to-main lifecycle.
#
# Features land in `nightly` first. Features worth keeping are promoted to
# `main` through a reviewed PR, and `main` is merged back into `nightly` so the
# branches do not drift apart. See CONTRIBUTING.md.
#
# Usage:
#   scripts/nightly.sh promote <PR>   Open a PR against main with the changes
#                                     of a PR that was merged into nightly.
#   scripts/nightly.sh sync           Open a PR that merges main into nightly.
#
# `promote` creates the branch `promote/<head branch>` from origin/main and
# cherry-picks the PR's merge commit. If the cherry-pick conflicts, resolve
# it, run `git cherry-pick --continue`, and rerun the same command to push the
# branch and open the PR. `sync` works the same way on the branch
# `sync/main-into-nightly`, created from origin/nightly with origin/main merged
# in; after a conflict, resolve it, run `git commit`, and rerun `sync`.
#
# Requires git and an authenticated gh CLI.
set -euo pipefail

remote="${NIGHTLY_REMOTE:-origin}"
nightly_branch="nightly"
main_branch="main"

die() {
    echo "error: $*" >&2
    exit 1
}

usage() {
    awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"
    exit "${1:-0}"
}

require_clean_tree() {
    if ! git diff --quiet || ! git diff --cached --quiet; then
        die "the working tree has uncommitted changes"
    fi
}

promote() {
    local pr="${1:-}"
    [[ "$pr" =~ ^[0-9]+$ ]] || usage 1

    local state base head merge_sha title body
    IFS=$'\t' read -r state base head merge_sha < <(
        gh pr view "$pr" --json state,baseRefName,headRefName,mergeCommit \
            --jq '[.state, .baseRefName, .headRefName, (.mergeCommit.oid // "")] | @tsv'
    )
    [[ "$base" == "$nightly_branch" ]] \
        || die "PR #$pr targets '$base', not '$nightly_branch'"
    [[ "$state" == "MERGED" && -n "$merge_sha" ]] \
        || die "PR #$pr is not merged into $nightly_branch yet"
    title="$(gh pr view "$pr" --json title --jq .title)"
    body="$(gh pr view "$pr" --json body --jq .body)"

    local branch="promote/${head}"

    if [[ "$(git branch --show-current)" == "$branch" ]]; then
        # Rerun after resolving a conflicted cherry-pick.
        [[ ! -e "$(git rev-parse --git-path CHERRY_PICK_HEAD)" ]] \
            || die "finish the cherry-pick first: git cherry-pick --continue"
    else
        require_clean_tree
        git show-ref --verify --quiet "refs/heads/$branch" \
            && die "branch '$branch' already exists; check it out to finish the promotion"
        git fetch "$remote" "$main_branch" "$merge_sha"
        git switch -c "$branch" "$remote/$main_branch"

        # Squash and rebase merges leave a single commit; a merge commit is
        # replayed relative to its first parent (the nightly side).
        local parents=()
        read -r -a parents < <(git rev-list --parents -n 1 "$merge_sha")
        local pick_args=(-x)
        if (( ${#parents[@]} > 2 )); then
            pick_args+=(-m 1)
        fi
        if ! git cherry-pick "${pick_args[@]}" "$merge_sha"; then
            echo >&2
            echo "Resolve the conflicts, run 'git cherry-pick --continue'," >&2
            echo "then rerun: $0 promote $pr" >&2
            exit 1
        fi
    fi

    git push --set-upstream "$remote" "$branch"
    local existing
    existing="$(gh pr list --head "$branch" --base "$main_branch" --state open \
        --json url --jq '.[0].url // ""')"
    if [[ -n "$existing" ]]; then
        echo "PR already open: $existing"
    else
        gh pr create --base "$main_branch" --head "$branch" \
            --title "$title" --body "$body"
    fi
}

sync() {
    git fetch "$remote" "$main_branch" "$nightly_branch"
    if git merge-base --is-ancestor "$remote/$main_branch" "$remote/$nightly_branch"; then
        echo "$nightly_branch already contains $main_branch."
        return
    fi

    local branch="sync/main-into-nightly"

    if [[ "$(git branch --show-current)" == "$branch" ]]; then
        # Rerun after resolving a conflicted merge.
        [[ ! -e "$(git rev-parse --git-path MERGE_HEAD)" ]] \
            || die "finish the merge first: git commit"
        git merge-base --is-ancestor "$remote/$main_branch" HEAD \
            || die "'$branch' does not contain $remote/$main_branch; delete it and rerun"
    else
        require_clean_tree
        git show-ref --verify --quiet "refs/heads/$branch" \
            && die "branch '$branch' already exists; check it out to finish the sync, or delete it"
        git switch -c "$branch" "$remote/$nightly_branch"
        if ! git merge --no-ff --no-edit "$remote/$main_branch"; then
            echo >&2
            echo "Resolve the conflicts, run 'git commit'," >&2
            echo "then rerun: $0 sync" >&2
            exit 1
        fi
    fi

    git push --force-with-lease --set-upstream "$remote" "$branch"
    local existing
    existing="$(gh pr list --head "$branch" --base "$nightly_branch" --state open \
        --json url --jq '.[0].url // ""')"
    if [[ -n "$existing" ]]; then
        echo "Sync PR already open: $existing"
    else
        gh pr create --base "$nightly_branch" --head "$branch" \
            --title "Merge main into nightly" \
            --body "Brings releases, promotions, and fixes from \`main\` into \`nightly\`. Merge this PR with a merge commit so \`nightly\` keeps \`main\`'s history."
    fi
}

case "${1:-}" in
    promote) shift; promote "$@" ;;
    sync) shift; sync "$@" ;;
    -h | --help | help) usage 0 ;;
    *) usage 1 ;;
esac
