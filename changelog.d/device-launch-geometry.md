### Changed

- Launch device kernels with 256-thread blocks instead of 16 and cap the grid
  at one resident wave where the device reports it; the grid-stride loop
  covers larger row counts. ([#182](https://github.com/larecs/larecs/pull/182))
