#!/usr/bin/env bash
# rebuild_nightly.sh — Rebuild `nightly` from `main` and the unpromoted feature
# branches.
#
# `nightly` is `main` plus feature branches under test. Rebuilding it drops
# features that were promoted to `main` or abandoned, and picks up releases and
# fixes from `main`. The script collects every remote branch that is merged
# into the current `nightly` but not into `main`, merges them onto `main` in the
# order they first reached `nightly`, and shows the result. Nothing is pushed
# without --push.
#
# Usage:
#   scripts/rebuild_nightly.sh [--add <branch>]... [--drop <branch>]... [--push]
#   scripts/rebuild_nightly.sh --continue [--push]
#
#   --add <branch>   Also merge this branch (e.g. one not yet in nightly).
#   --drop <branch>  Leave this branch out (abandoned work).
#   --push           Force-push the result to origin/nightly. Requires
#                    permission to bypass the nightly ruleset.
#   --continue       Resume after resolving a merge conflict and committing.
#
# The rebuild runs on the local branch `nightly-rebuild`. Conflicts are
# recorded with git rerere, so a resolution is reused by later rebuilds.
#
# Pull request merges select a branch only when their source owner matches the
# remote. Set NIGHTLY_REMOTE_OWNER when the remote is not a GitHub URL.
set -euo pipefail

remote="${NIGHTLY_REMOTE:-origin}"
work_branch=nightly-rebuild
state_file="$(git rev-parse --git-path rebuild-nightly-todo)"
base_file="$(git rev-parse --git-path rebuild-nightly-base)"

die() {
    echo "error: $*" >&2
    exit 1
}

usage() {
    awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"
    exit "${1:-0}"
}

adds=()
drops=()
push=false
resume=false
while (( $# > 0 )); do
    case "$1" in
        --add) adds+=("${2:?--add needs a branch}"); shift 2 ;;
        --drop) drops+=("${2:?--drop needs a branch}"); shift 2 ;;
        --push) push=true; shift ;;
        --continue) resume=true; shift ;;
        -h | --help) usage 0 ;;
        *) usage 1 ;;
    esac
done

git_rr() {
    git -c rerere.enabled=true -c rerere.autoUpdate=true "$@"
}

lowercase() {
    printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

remote_owner() {
    local url owner_pattern='^(https://([^/@]+@)?|ssh://git@|git@)github\.com[:/]([^/:]+)/[^/]+/?$'
    if [[ -n "${NIGHTLY_REMOTE_OWNER:-}" ]]; then
        lowercase "$NIGHTLY_REMOTE_OWNER"
        return 0
    fi
    url="$(git remote get-url "$remote")"
    if [[ "$url" =~ $owner_pattern ]]; then lowercase "${BASH_REMATCH[3]}"; fi
    return 0
}

pull_request_selects() {
    # A pull request subject names a repository branch only for the same owner.
    local subject="$1" branch="$2" owner="$3" source
    [[ "$subject" == "Merge pull request #"*" from "* ]] || return 1
    source="${subject#* from }"
    [[ "${source#*/}" == "$branch" ]] || return 1
    if [[ -z "$owner" ]]; then
        rm -f "$state_file"
        die "cannot determine the owner of $remote for '$subject'; set NIGHTLY_REMOTE_OWNER"
    fi
    [[ "$(lowercase "${source%%/*}")" == "$owner" ]]
}

collect_branches() {
    # Unpromoted remote branches, including tips advanced or rewritten since
    # integration, ordered by their earlier merge on nightly's first-parent line.
    local candidates=() ref
    while read -r ref; do
        case "$ref" in
            "$remote" | "$remote/HEAD" | "$remote/main" | "$remote/nightly" | "$remote/nightly-history/"* | "$remote/gh-pages" | "$remote/release/"*) continue ;;
        esac
        if ! git merge-base --is-ancestor "$ref" "$remote/main"; then
            candidates+=("${ref#"$remote/"}")
        fi
    done < <(git for-each-ref --format='%(refname:short)' "refs/remotes/$remote")

    # Stacked branches: lower branches (fewer commits ahead of main) first.
    if (( ${#candidates[@]} > 0 )); then
        local sorted=()
        while read -r _ ref; do sorted+=("$ref"); done < <(
            for ref in "${candidates[@]}"; do
                echo "$(git rev-list --count "$remote/main..$remote/$ref") $ref"
            done | sort -n -s -k1,1
        )
        candidates=("${sorted[@]}")
    fi

    local commit branch subject owner ordered=() assigned=" "
    owner="$(remote_owner)"
    while read -r commit; do
        subject="$(git log -1 --format=%s "$commit")"
        for branch in "${candidates[@]+"${candidates[@]}"}"; do
            [[ "$assigned" == *" $branch "* ]] && continue
            # Contained tips are already tested. Advanced or rewritten tips
            # require the branch's own merge subject: a shared ancestor alone
            # could also belong to a stacked branch never merged into nightly.
            if git merge-base --is-ancestor "$remote/$branch" "$commit" \
                || [[ "$subject" == "Merge branch '$branch' into nightly" ]] \
                || [[ "$subject" == "Merge remote-tracking branch '$remote/$branch' into nightly" ]] \
                || pull_request_selects "$subject" "$branch" "$owner"; then
                ordered+=("$branch")
                assigned+="$branch "
            fi
        done
    done < <(git rev-list --first-parent --reverse "$remote/main..$remote/nightly")

    for branch in "${adds[@]+"${adds[@]}"}"; do
        [[ "$assigned" == *" $branch "* ]] || { ordered+=("$branch"); assigned+="$branch "; }
    done
    for branch in "${ordered[@]+"${ordered[@]}"}"; do
        [[ " ${drops[*]+"${drops[*]}"} " == *" $branch "* ]] || echo "$branch"
    done
}

merge_branches() {
    local branch
    while [[ -s "$state_file" ]]; do
        branch="$(head -n 1 "$state_file")"
        if git merge-base --is-ancestor "$remote/$branch" HEAD; then
            echo "= $branch (already contained)"
        else
            echo "+ $branch"
            if ! git_rr merge --no-ff --no-edit -m "Merge branch '$branch' into nightly" "$remote/$branch"; then
                [[ -e "$(git rev-parse --git-path MERGE_HEAD)" ]] || die "could not merge $remote/$branch"
                if [[ -z "$(git diff --name-only --diff-filter=U)" ]]; then
                    # rerere resolved every conflict.
                    git commit --no-edit
                else
                    echo >&2
                    echo "Resolve the conflicts, run 'git commit', then: $0 --continue" >&2
                    exit 1
                fi
            fi
        fi
        sed -i.bak '1d' "$state_file" && rm -f "$state_file.bak"
    done
}

if [[ "$resume" == true ]]; then
    [[ -f "$state_file" ]] || die "no rebuild in progress"
    [[ "$(git branch --show-current)" == "$work_branch" ]] || die "switch to $work_branch first"
    [[ ! -e "$(git rev-parse --git-path MERGE_HEAD)" ]] || die "finish the merge first: git commit"
    # merge_branches verifies containment before removing the queued branch,
    # and retries it if the interrupted merge was aborted or never started.
else
    if ! git diff --quiet || ! git diff --cached --quiet; then
        die "the working tree has uncommitted changes"
    fi
    git fetch --prune "$remote"
    collect_branches > "$state_file"
    git rev-parse "$remote/nightly" > "$base_file"
    echo "Rebuilding nightly from $remote/main with:"
    sed 's/^/  /' "$state_file"
    git switch -C "$work_branch" "$remote/main"
fi

merge_branches
rm -f "$state_file"

old="$(cat "$base_file")"
echo
echo "Dropped from nightly (promoted or abandoned):"
git log --oneline --no-merges "HEAD..$old" | sed 's/^/  /' || true
echo "Changed files relative to the current nightly:"
git diff --stat "$old" HEAD | tail -n 1

if [[ "$push" == true ]]; then
    # Keep old integration commits reachable for the feature-branch check.
    # Publish the archive and replacement together, or change neither ref.
    git push --atomic --force-with-lease="nightly:$old" "$remote" \
        "$old:refs/heads/nightly-history/$old" "HEAD:refs/heads/nightly"
    rm -f "$base_file"
    echo "Pushed the rebuilt nightly."
else
    echo
    echo "Inspect $work_branch, then publish it with: git push --atomic --force-with-lease=nightly:$old $remote $old:refs/heads/nightly-history/$old $work_branch:refs/heads/nightly"
fi
