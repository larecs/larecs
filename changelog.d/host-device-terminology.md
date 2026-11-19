### Breaking changes

- Select the kernel target with the compile-time
  `backend=ExecutionBackend.HOST/DEVICE` parameter on ordinary and selected
  execution instead of the `on_gpu` flag. Host remains the default;
  unavailable device execution raises instead of falling back, and
  value-taking callables require `HOST`. ([#181](https://github.com/larecs/larecs/pull/181), [#216](https://github.com/larecs/larecs/pull/216))

- Rename `GPUComponentType`/`GPUResourceType` to
  `DeviceComponentType`/`DeviceResourceType` and
  `constrain_gpu_safe_components`/`constrain_gpu_safe_resources` to
  `constrain_device_safe_components`/`constrain_device_safe_resources`.
  ([#181](https://github.com/larecs/larecs/pull/181))
