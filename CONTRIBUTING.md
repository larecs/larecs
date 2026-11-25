# Contributing to Larecs🌲

## Land a change

1. Find or open the issue and create a linked branch from `main`. For stacked
   work, use the branch the change builds on.

   ```sh
   gh issue develop <issue> --name <branch> --base main --checkout
   ```

2. Describe user-visible changes in a [changelog fragment](changelog.d/).
3. Open a PR and merge it after the required checks pass. Changes to GitHub
   workflow files and release verification also require a maintainer review.

## Try a nightly build

[Release nightly](.github/workflows/release-nightly.yml) publishes from `main`
daily at 02:17 UTC when the commit changes. Maintainers can also run it manually
or set the `NIGHTLY_SOURCE` repository variable to select a different branch.
Nightly packages append the commit's UTC time and workflow run number to the
latest release tag reachable from the source branch.

```sh
pixi workspace channel add --prepend https://prefix.dev/tree-d/nightly
pixi add larecs
```

The workspace also needs the `conda-forge`, `https://repo.prefix.dev/max`, and
`https://prefix.dev/tree-d` channels for Larecs's dependencies.

## Publish a release

1. Collect changelog fragments with
   `python3 scripts/changelog.py release <version> --previous <previous-version>`.
   Merge the changelog update into `main`.
2. Run `python3 scripts/release_pr.py open <tag> [main-commit]`. The command
   opens a PR from the selected commit against the most recent release. Keep
   the generated **Try the release candidate** section directly after the
   opening description so readers can build the candidate with Pixi. Use
   **Files changed** for the full diff and the linked PRs for context.
3. After an approving review and passing checks, merge the release PR using
   **Create a merge commit**. If the release needs a fix, land it on `main`
   and update the candidate branch to the new commit for review.
4. Follow the **Release** workflow that starts when the PR merges. It tests
   and publishes the reviewed commit, then removes the temporary branches.

[AGENTS.md](AGENTS.md) lists build and test commands, code style, and guidance
for issues and PR descriptions.
