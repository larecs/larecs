"""Lifecycle counters for tests of non-trivial component storage."""

from std.memory import alloc, dealloc, Layout, Allocation

from larecs.test_utils import MemTestStruct


comptime TrackedComponent = MemTestStruct[
    MutUnsafeAnyOrigin, MutUnsafeAnyOrigin, MutUnsafeAnyOrigin
]


struct LifecycleCounters(Movable):
    """Lifecycle operation counters for non-trivial component tests."""

    var _copy_counter: Allocation[Int]
    """The number of copy initializations."""

    var _move_counter: Allocation[Int]
    """The number of move initializations."""

    var _del_counter: Allocation[Int]
    """The number of destructor calls."""

    def __init__(out self):
        """Initializes copy, move, and delete counters to zero."""
        self._copy_counter = alloc(Layout[Int].single())
        self._move_counter = alloc(Layout[Int].single())
        self._del_counter = alloc(Layout[Int].single())
        self._copy_counter.unsafe_ptr().unsafe_write(0)
        self._move_counter.unsafe_ptr().unsafe_write(0)
        self._del_counter.unsafe_ptr().unsafe_write(0)

    def __deinit__(deinit self):
        """Destroys and frees the allocated lifecycle counters."""
        self._copy_counter.unsafe_ptr().unsafe_deinit_pointee()
        self._move_counter.unsafe_ptr().unsafe_deinit_pointee()
        self._del_counter.unsafe_ptr().unsafe_deinit_pointee()
        dealloc(self._copy_counter^)
        dealloc(self._move_counter^)
        dealloc(self._del_counter^)

    def del_counter(ref self) -> Int:
        """Returns the current delete counter value."""
        return self._del_counter.unsafe_ptr()[]

    def copy_counter(ref self) -> Int:
        """Returns the current copy counter value."""
        return self._copy_counter.unsafe_ptr()[]

    def move_counter(ref self) -> Int:
        """Returns the current move counter value."""
        return self._move_counter.unsafe_ptr()[]

    def component(ref self) -> TrackedComponent:
        """Creates a tracked component connected to these counters.

        Returns:
            A component whose copy, move, and destructor operations increment
            this counter set.
        """
        return TrackedComponent(
            self._copy_counter.unsafe_ptr()
            .as_unsafe_any_origin()
            .mut_cast[True](),
            self._move_counter.unsafe_ptr()
            .as_unsafe_any_origin()
            .mut_cast[True](),
            self._del_counter.unsafe_ptr()
            .as_unsafe_any_origin()
            .mut_cast[True](),
        )
