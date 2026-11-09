+++
type = "docs"
title = "Regression-check runtime evidence"
weight = 8
+++

These are recorded execution budgets for an unchanged-library comparison,
not platform speed rankings. The hosted record identifies merge checkout
`ba8b180`; the earlier local record identifies baseline `688fb67` but not its
exact current checkout SHA. Hardware/compiler, method, excluded costs, and
confirmation limits are preserved below. Current commands and failure rules
live in [regression operation](../../regression).

## Initial gate measurements

The initial unchanged-library comparison against `688fb67` on Apple M4,
macOS 27 arm64, Mojo 1.0.0 (`ed45d567`), took **55.3 seconds**: core builds
9.3/9.6 seconds and sampling 2.6 seconds; spatial builds 5.8/5.4 seconds and
sampling 22.2 seconds. Builds and samples ran sequentially; no concurrent
builds or benchmark jobs ran. These are driver compilation costs in an already
installed environment, not dependency installation time.

The first [hosted run](https://github.com/larecs/larecs/actions/runs/37112210067)
compared the same unchanged library against `688fb67`, using PR merge checkout
`ba8b180`, Mojo 1.0.0 (`ed45d567`), the same current driver on each side, fresh
output binaries, sequential compilation/sampling, and five alternating pairs.
Both suites passed without confirmation, and both artifact uploads succeeded:

| Runner | CPU / OS | All driver builds | All sampling | Total gate |
| --- | --- | ---: | ---: | ---: |
| `macos-latest` | Apple M2 Pro (Virtual), macOS 26.6.2 arm64 | 43.1 s | 22.1 s | 66.1 s |
| `ubuntu-latest` | AMD EPYC 7763, Linux 6.17 x86_64 / glibc 2.39 | 50.2 s | 24.6 s | 75.3 s |

These are one-run runtime measurements, not speed comparisons between platforms
or evidence that the runner's load is stable. Full correctness tests, examples,
package checks, and environment installation are excluded from these gate
costs. The combined check stays near a minute; further coverage requires new
budget measurements on both platforms. Confirmation adds sampling cost for
affected suites; command deadlines bound failures rather than promising
a one-minute runtime for all error/confirmation paths.
