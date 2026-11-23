+++
type = "docs"
title = "Develop a feature"
weight = 110
+++

Develop on a feature branch, merge through CI, and try the change in a nightly
package. Stable releases review the changes together in a release PR.

## Open a feature PR

Create a branch linked to the issue. Use the parent feature branch as the base
if the work depends on an open PR.

```sh
gh issue develop <issue> --name <branch> --base main --checkout
```

Record user-visible changes in a
[changelog fragment](https://github.com/larecs/larecs/blob/main/CONTRIBUTING.md#land-a-change).
Open a PR and merge it after the required checks pass. Changes to the release
tooling also require code-owner review.

## Test the nightly package

The nightly workflow builds from `main`. In a Pixi workspace, put the nightly
channel before the stable channel:

```sh
pixi workspace channel add --prepend https://prefix.dev/tree-d/nightly
pixi add larecs
```

## Review a stable release

A release PR compares the previous release with a pinned commit on `main`.
Review the full diff and follow the linked feature PRs for context. Merging an
approved release PR starts the package checks and publishes the reviewed commit
once they pass. The
[contributor guide](https://github.com/larecs/larecs/blob/main/CONTRIBUTING.md)
has the commands to prepare a release PR.
