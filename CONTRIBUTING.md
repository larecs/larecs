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

2. **Open a PR into `nightly`.** Merge it yourself once the required checks
   pass; no approval is needed. Prefer squash merges, so each feature is one
   commit that is easy to promote. Issues named with `Closes #N` are closed when
   the PR merges into `nightly`.

3. **Try it out.** The [Release nightly](.github/workflows/release-nightly.yml)
   workflow builds, tests, and publishes `nightly` every day at 02:17 UTC when
   the branch changed. Maintainers can start it manually from the Actions tab.

4. **Promote features worth keeping to `main`.** This opens a reviewed PR
   against `main` with the changes of a merged nightly PR, reusing its title
   and description:

   ```sh
   scripts/nightly.sh promote <nightly PR>
   ```

   The script creates `promote/<feature branch>` from `main` and cherry-picks
   the merge commit. If the cherry-pick conflicts, resolve it, run
   `git cherry-pick --continue`, and rerun the command. Features that are not
   promoted stay in `nightly` until they are reverted or reworked there.

5. **Release from `main`.** Promoted features reach users with the next
   periodic stable release, published by the [Release](.github/workflows/release.yml)
   workflow.

6. **Merge `main` back into `nightly`** after releases and promotions, so
   release tags, version bumps, and review fixes made on `main` reach
   `nightly`:

   ```sh
   scripts/nightly.sh sync
   ```

   Merge the resulting PR with a merge commit, not a squash. If the merge
   conflicts, resolve it, run `git commit`, and rerun the command.

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
