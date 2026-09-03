"""Warning-printing helpers used throughout the library.

Provides `warn`, which always prints, and `debug_warn`, which only prints
when compiled with `DEBUG_MODE` defined.
"""

from std.sys.defines import is_defined

from tracy import Zone


@always_inline
def warn(msg: Some[Writable]) -> None:
    """Prints a warning message.

    Args:
        msg: The message to print.
    """
    with Zone(function_name="debug_utils.warn(msg: Some[Writable])"):
        print("Warning: ", msg)


@always_inline
def debug_warn(msg: Some[Writable]) -> None:
    """Prints a debug warning message.

    Args:
        msg: The message to print.
    """

    with Zone(function_name="debug_utils.debug_warn(msg: Some[Writable])"):
        comptime if is_defined["DEBUG_MODE"]():
            warn(msg)
