### Breaking changes

- Select kernel execution with `backend=ExecutionBackend.HOST` (default) or
  `backend=ExecutionBackend.DEVICE` instead of a boolean target flag. Device
  execution raises when the requested backend is unavailable.
