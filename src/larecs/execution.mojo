"""Configuration and invocation guard for experimental threaded host execution."""


struct ThreadedExecutionConfig(Copyable, Movable):
    """Immutable scheduling settings; configuration alone does not enable threading.

    MAX owns the shared CPU runtime. Workers bound submitted tasks, not reserved
    cores or persistent OS threads. Construct custom settings with ``workers``.
    """

    var _workers: Int
    var _chunks_per_worker: Int
    var _min_parallel_rows: Int

    def __init__(out self):
        """Uses one worker, four chunks per worker, and a 65,536-row cutoff."""
        self._workers = 1
        self._chunks_per_worker = 4
        self._min_parallel_rows = 65_536

    def __init__(
        out self,
        *,
        workers: Int,
        chunks_per_worker: Int = 4,
        min_parallel_rows: Int = 65_536,
    ) raises:
        """Validates and stores fixed scheduling settings.

        Args:
            workers: Positive maximum submitted worker tasks.
            chunks_per_worker: Positive target chunks per worker.
            min_parallel_rows: Nonnegative matched-row cutoff; zero disables it.

        Raises:
            Error: If settings are invalid or their product overflows Int.
        """
        if workers <= 0 or chunks_per_worker <= 0 or min_parallel_rows < 0:
            raise Error("Invalid threaded execution configuration")
        if workers > Int(Int64.MAX) // chunks_per_worker:
            raise Error("Threaded chunk target overflows Int")
        self._workers = workers
        self._chunks_per_worker = chunks_per_worker
        self._min_parallel_rows = min_parallel_rows

    def workers(self) -> Int:
        """Returns the maximum submitted worker-task count.

        Returns:
            Configured positive task budget.
        """
        return self._workers

    def chunks_per_worker(self) -> Int:
        """Returns the target number of chunks per worker.

        Returns:
            Configured positive chunk target.
        """
        return self._chunks_per_worker

    def min_parallel_rows(self) -> Int:
        """Returns the minimum matched rows for parallel dispatch.

        Returns:
            Nonnegative cutoff, with zero disabling the cutoff.
        """
        return self._min_parallel_rows


struct _ExecutionGuard(Movable):
    """Caller-confined RAII flag; this is not a mutex for external callers."""

    var _active: Pointer[Bool, MutUntrackedOrigin]

    def __init__(out self, active: Pointer[Bool, MutUntrackedOrigin]) raises:
        """Marks the world active until destruction.

        Args:
            active: Stable world-owned flag, retained until synchronous join.

        Raises:
            Error: If execution is already active.
        """
        if active[]:
            raise Error("World execution is already active")
        self._active = active
        active[] = True

    def __deinit__(deinit self):
        """Clears the flag after workers and invocation owners are released."""
        self._active[] = False
