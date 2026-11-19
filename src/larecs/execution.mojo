"""Explicit kernel backends, threaded host configuration and invocation guards."""


@fieldwise_init
struct ExecutionBackend(Equatable, TrivialRegisterPassable):
    """Explicit kernel target, selected at compile time with ``backend=``.

    ``HOST`` is the default. ``DEVICE`` requires a working accelerator and never
    falls back to the host. Value-taking callables support only ``HOST``.
    """

    comptime HOST = Self(0)
    """Execute synchronously using host storage."""
    comptime DEVICE = Self(1)
    """Execute synchronously using device storage and copy back writes."""

    var _value: Int

    def __eq__(self, other: Self) -> Bool:
        """Compares backend choices.

        Args:
            other: Backend to compare.

        Returns:
            Whether both choices are equal.
        """
        return self._value == other._value
