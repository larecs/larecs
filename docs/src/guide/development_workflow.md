+++
type = "docs"
title = "Develop a feature"
weight = 110
+++

Every change to Larecs🌲 is developed on its own feature branch. The branch is
merged into `nightly`, where it is tested and published as a nightly package
without review, and the same branch is later promoted to `main` through a
reviewed PR. Because both branches receive the same commits, `main` and
`nightly` never need to be reconciled.

![Feature branches merge into nightly for testing and into main when promoted; nightly is rebuilt after each release](/images/development-workflow.svg)

*A feature branch reaches `nightly` once per PR and `main` once, when it is
promoted. The rebuilt `nightly` keeps only features that were not promoted.*

## Branches

| Branch | Contains | Merge requirements | Packages |
| --- | --- | --- | --- |
| feature branch | One feature, started from `main` | — | — |
| `nightly` | `main` plus feature branches under test | Passing checks, merge commit | Daily to [`tree-d/nightly`](https://prefix.dev/tree-d/nightly) |
| `main` | Promoted features and releases | Passing checks, one approval, merge commit | Each release to [`tree-d`](https://prefix.dev/tree-d) |

## 1. Start a feature branch from `main`

Create the branch from `main` and link it to its issue:

```sh
gh issue develop <issue> --name <branch> --base main --checkout
```

When a feature needs another unpromoted feature, start it from that feature's
branch instead. It then reaches `main` only after the feature below it.

## 2. Describe the change in a changelog fragment

Add `changelog.d/<feature>.md` with the user-visible changes of the feature,
grouped under `### Breaking changes`, `### Added`, `### Changed`, `### Fixed`,
or `### Removed`. Each entry describes the feature as it currently behaves and
ends with links to the PRs that shaped it:

```markdown
### Added

- Add opt-in threaded host execution. ([#187](https://github.com/larecs/larecs/pull/187))
```

The fragment travels with the branch, so `nightly` and `main` each list exactly
the features they contain. Changes that users do not notice, such as CI
tweaks, need no fragment; label their PRs `no-changelog`.

## 3. Test the feature on `nightly`

Open a PR from the feature branch into `nightly`. It needs passing checks but
no approval; merge it yourself with **Create a merge commit**. The
[Release nightly](https://github.com/larecs/larecs/blob/main/.github/workflows/release-nightly.yml)
workflow publishes the result once a day to `https://prefix.dev/tree-d/nightly`.
To try it in a Pixi workspace, put that channel before the stable one:

```sh
pixi workspace channel add --prepend https://prefix.dev/tree-d/nightly
pixi add larecs
```

Never merge `nightly` into the feature branch, and never use **Update branch**
on a PR into `nightly`: that would carry every other feature under test into
`main` on promotion. The **Feature branch base** check fails PRs whose branch
contains such commits.

## 4. Refine the feature on the same branch

Push follow-up commits to the same feature branch and open a new PR into
`nightly`. In the same PR, rewrite the fragment entry to describe the new
behavior and append the new PR's link. Before promotion, you may squash or
reword the branch's own commits; the next `nightly` rebuild picks up the
cleaned branch.

## 5. Promote the feature to `main`

Open a PR from the feature branch into `main`. It needs one approval; merge it
with **Create a merge commit**. Review covers the feature as a whole, and
cleanups requested in review are pushed to the branch. Since `nightly`
already holds the same commits, nothing has to be copied or reconciled.

## 6. Release, then rebuild `nightly`

A release collects all fragments on `main` into a new section of
`changelog.md` and deletes them:

```sh
python3 scripts/changelog.py release <version> --previous <previous version>
```

After the release, or whenever `nightly` should drop promoted or abandoned
features, a maintainer rebuilds it:

```sh
scripts/rebuild_nightly.sh            # show the plan and build nightly-rebuild
scripts/rebuild_nightly.sh --push     # rebuild and force-push nightly
```

The script merges onto `main` every remote branch that `nightly` contains but
`main` does not, in the order they reached `nightly`. `--add <branch>` includes
a branch that is not in `nightly` yet, and `--drop <branch>` leaves out
abandoned work. If a merge conflicts, resolve it, run `git commit`, and
continue with `scripts/rebuild_nightly.sh --continue`; git remembers the
resolution for later rebuilds. Pushing requires permission to bypass the
`nightly` branch rules.
