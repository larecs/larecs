+++
type = "docs"
title = "Resource execution measurements"
weight = 6
+++

This report records Apple M4/macOS 27.0.1 results with Mojo 1.0.0 (`ed45d567`),
base `6a3841b`, and the portable-adapter work recorded in `fde2cb9`.
The original text did not identify the exact measured current-tree SHA;
`fde2cb9` identifies the retained report/driver, not proof of a clean timed tree.
The measured read-only adapter implementation predates later mutable-adapter
and device-copy-reuse work. Its transfer costs are not current API guarantees.
Below, "current" means that measured candidate rather than today's checkout.

## Resource execution

`resource_execution_benchmark.mojo` uses the current execution API. Compare the
same workload against the base library, adapting only backend call spelling
when the base predates `ExecutionBackend`. It measures complete calls over 512 Int32 rows with either no
resources or one legacy scalar resource. `resource_adapter_benchmark.mojo`
measures current read-only adapters over the same rows and 4,096 initial Int32
samples. Only the first sample is read; the entire source is uploaded. Each timed
adapter call edits that sample, and growth cases append one sample per call.
Host calls use 10,000 iterations; GPU calls use 100. One warmup invocation precedes
each timer. Construction and final checks are excluded; validation, leases,
component transfers, resource uploads/downloads, allocation growth, and
synchronization are included when applicable. Exact outputs, row counts, source
values, and final sample lengths are checked outside timing.

Copy the current driver for the baseline build:

```sh
cp benchmark/resource_execution_benchmark.mojo /tmp/resource_base.mojo
```

If the base accepts `on_device: Bool` rather than `backend: ExecutionBackend`,
adapt only that copy before compiling it:

```sh
python - <<'PYCODE'
from pathlib import Path
import re

path = Path("/tmp/resource_base.mojo")
source = path.read_text().replace("    ExecutionBackend,\n", "")
source, count = re.subn(
    r"backend=\(\s*ExecutionBackend\.DEVICE if device else ExecutionBackend\.HOST\s*\)",
    "on_device=device",
    source,
)
assert count == 4, "Review the driver before adapting a changed call matrix"
assert "ExecutionBackend" not in source.split('from std.time', 1)[1]
path.write_text(source)
PYCODE
```

This maps the same compile-time `device` boolean to the older keyword; kernels,
row counts, iterations, warmup, validation, and timing boundaries stay identical.
Do not substitute a historical driver with different workloads. Device comparisons
require a working accelerator on both sides; an older host fallback is not a
device measurement. For a base using `on_gpu`, use that keyword instead.

Build optimized binaries once without debug information, sanitizers, or tracing:

```sh
pixi run mojo build -I /path/to/base/src /tmp/resource_base.mojo -o /tmp/resource-base
pixi run mojo build -I src benchmark/resource_execution_benchmark.mojo -o /tmp/resource-current
pixi run mojo build -I src benchmark/resource_adapter_benchmark.mojo -o /tmp/resource-adapters
```

On Apple M4, macOS 27.0.1, Mojo `1.0.0 (ed45d567)`, compare base `6a3841b`
against this implementation with the same driver. Warm each binary, then run five
paired samples, alternating base/current order, with no concurrent compilation
or benchmark jobs. Median per-call means were:

| Complete invocation | Base | Current |
| --- | --- | --- |
| Host, no resource | 294.2 ns | 299.6 ns |
| Host, legacy scalar resource | 299.8 ns | 350.7 ns |
| GPU, no resource | 250.50 µs | 251.52 µs |
| GPU, legacy scalar resource | 243.51 µs | 268.59 µs |
| Host, edited adapter | — | 449.1 ns |
| Host, edited adapter plus growth | — | 451.4 ns |
| GPU, edited adapter | — | 323.76 µs |
| GPU, edited adapter plus growth | — | 303.54 µs |

The scalar GPU case costs about 10.3% more with staged publication and lifetime
protection. These measurements establish the cost of this synthetic workload,
not an application speedup or Tree-D shading result. Short GPU batches are noisy;
the growth-case ordering does not establish a growth benefit. Source/sample allocation
and scientific preprocessing during initial construction are excluded; incremental
host append and device allocation growth are included in growth cases. Existing
allocation capacity is reused in nongrowing cases; contents are uploaded every run.

Sequential base/current/adapter driver builds took 1.18/3.00/3.01 seconds with
existing compiler caches and no competing builds. These are recorded build costs,
not comparable cold-compilation measurements.
Linux resource timings and cold compilation remain unmeasured. These focused
manual cases do not enlarge the normal PR performance matrix.
