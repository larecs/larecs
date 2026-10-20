"""Granularity of the Tracy zones larecs records.

With `TRACY_ENABLED`, larecs always records coarse zones: the scheduler,
system updates, kernel runs, device transfers and synchronization, and batch
storage operations. Zones in per-entity and per-component helpers, such as
component access and entity iteration, run many times per system call; their
instrumentation cost would dominate a profile. They are recorded only with
`-D LARECS_FINE_ZONES`.
"""

from std.sys.defines import is_defined

from tracy import Zone

comptime FineZone = Zone[enabled=is_defined["LARECS_FINE_ZONES"]()]
"""A zone recorded only when larecs is built with `-D LARECS_FINE_ZONES`."""
