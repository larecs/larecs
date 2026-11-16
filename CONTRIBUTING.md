# Contributing to Larecs🌲

## Branches

| Branch    | Receives                                       | Merge requirements                   | Packages                                                             |
| --------- | ---------------------------------------------- | ------------------------------------ | -------------------------------------------------------------------- |
| `nightly` | Feature, fix, and documentation PRs            | Passing checks, no approving review  | Daily, to [`tree-d/nightly`](https://prefix.dev/tree-d/nightly)      |
| `main`    | Promotions from `nightly`, release preparation | Passing checks and one approval      | Each GitHub release, to [`tree-d`](https://prefix.dev/tree-d)        |

## Lifecycle of a change

1. **Develop on a branch from `nightly`.** Find or open the issue first, then
   create the linked branch:

   ```sh
   gh issue develop <issue> --name <branch> --base nightly --checkout
   ```

   Stacked work uses the branch it builds on as `--base` instead.

2. **Keep the changelog entry current.** The Unreleased section of
   [changelog.md](changelog.md) on `nightly` has one entry per feature or fix
   that reached `nightly`. Each entry describes the feature as it currently
   behaves and ends with links to every PR that shaped it:

   ```markdown
   - Add opt-in threaded host execution. ([#187](https://github.com/larecs/larecs/pull/187), [#212](https://github.com/larecs/larecs/pull/212))
   ```

   A PR with a new feature adds an entry in the matching subsection. A PR that
   refines, fixes, or reworks a feature already listed rewrites that entry to
   match the new behavior and appends its own link. The
   [Nightly changelog](.github/workflows/nightly-changelog.yml) check fails
   unless the Unreleased section links the PR. Label PRs that change nothing
   users notice, such as CI tweaks, `no-changelog`.

3. **Open a PR into `nightly`.** Merge it yourself once the required checks
   pass; no approval is needed. Prefer squash merges, so each PR is one commit
   on `nightly`. Issues named with `Closes #N` are closed when
   the PR merges into `nightly`.

4. **Try it out.** The [Release nightly](.github/workflows/release-nightly.yml)
   workflow builds, tests, and publishes `nightly` every day at 02:17 UTC when
   the branch changed. Maintainers can start it manually from the Actions tab.

5. **Promote features worth keeping to `main`.** Name the features as their
   entries in the `nightly` changelog describe them. A promotion brings each
   feature to `main` in its final form as one reviewed change, not as a replay
   of the nightly PRs that built it up:

   - Start a branch from `main`, such as `promote/<topic>`.
   - Bring over the feature's current state on `nightly`. When the PRs linked
     from its entry apply cleanly, cherry-pick their merge commits in order
     without committing (`git cherry-pick -n`) and commit the result once.
     Otherwise take the feature's files or hunks from `origin/nightly`, leaving
     out code that belongs to features not being promoted.
   - Consolidate where the nightly history shows it: fold related entries into
     one feature, drop intermediate APIs that later PRs replaced, and clean up
     code, docs, and tests that review on `main` asks for.
   - Write `main`'s changelog entries for the promoted behavior. Each entry ends
     with the links of all nightly PRs it covers, so it is clear which nightly
     entries are promoted.

   Open the PR against `main`. Features that are not promoted stay in
   `nightly` until they are reverted or reworked there.

6. **Release from `main`.** Promoted features reach users with the next
   periodic stable release, published by the [Release](.github/workflows/release.yml)
   workflow. The release moves `main`'s Unreleased entries into the new
   version's section.

7. **Merge `main` back into `nightly`** after releases and promotions, so
   release tags, version bumps, changelog sections, and review fixes made on
   `main` reach `nightly`:

   ```sh
   git switch -c sync/main-into-nightly origin/nightly
   git merge --no-ff origin/main
   ```

   Open a PR into `nightly`, label it `no-changelog`, and merge it with a merge
   commit, not a squash. Refinements made during promotion now reach `nightly`
   too. When resolving changelog conflicts, take `main`'s entries, remove the
   nightly entries whose PR links all appear in them, and keep every other
   nightly entry under Unreleased.

Urgent fixes for a stable release may target `main` directly; sync them into
`nightly` afterwards.

## Nightly versions

Nightly packages are versioned as the latest release tag on `nightly` plus the
UTC time of its newest commit, for example `1.0.0b2.202611160230`. They sort
after that release and before the next one.

To use them in a Pixi workspace, put the nightly channel before the stable one:

```sh
pixi workspace channel add --prepend https://prefix.dev/tree-d/nightly
pixi add larecs
```

The workspace also needs the `conda-forge`, `https://repo.prefix.dev/max`, and
`https://prefix.dev/tree-d` channels for Larecs's dependencies.

## Code, tests, and PR descriptions

[AGENTS.md](AGENTS.md) lists the build and test commands, the code style, and
the rules for issues and PR descriptions. The PR template is in
[.github/pull_request_template.md](.github/pull_request_template.md).
