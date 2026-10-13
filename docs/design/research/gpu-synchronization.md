# GPU synchronization research

Researched 2026-10-13 for [decision 0016](../decisions/0016-kernel-memory-synchronization.md).
“Merge standard library” is interpreted as the Mojo standard library.

GPU synchronization covers several separate contracts: atomic updates, memory
ordering, rendezvous between participants, resource permits, and completion of
asynchronous work. Larecs needs atomic scalars and a scoped reader/writer access
layer; collective barriers and pipeline signals solve additional problems but
do not directly supply that ownership layer.

This is research evidence, not an accepted design or a hardware capability
certification. The project lockfile selects Mojo 1.0.0 and MAX 26.5.0. Public
documentation currently spans versioned Mojo references, older `std.gpu` pages,
and newer `max.gpu` pages. Source observations below are pinned to Modular
revision `4b0d20f5160137da0b6e9c63503d282cfcea8551`; they describe upstream source,
not necessarily the project's installed release. No compilation, GPU execution,
or performance measurements were performed for this note.

## Primitive families

| Family | What it establishes | Typical scope | What it does not establish |
| --- | --- | --- | --- |
| Atomic load/store/RMW/CAS | One indivisible scalar operation, with selected ordering | Block, device, or system where supported | A transaction over several ordinary fields |
| Memory fence | Ordering of memory operations under a synchronization protocol | Block, device, system | A rendezvous or exclusive ownership |
| Warp/subgroup barrier | Coordination of a specified subgroup | Warp/wave/SIMD group | Coordination with other blocks; identical semantics on all backends |
| Block barrier | Participants reach a phase boundary, with defined memory visibility | One block/threadgroup | Exclusion among arbitrary accesses |
| Split-phase barrier | Arrival can precede waiting; tracks a reusable phase | Declared participants | An automatic reader/writer lock |
| Semaphore | Permits or state transitions, depending on the API | Declared synchronization domain | Container thread safety or universal progress |
| Pipeline / async completion | A stage's data is ready and its buffers may be reused | Producer/consumer group | Protection of unrelated memory |
| Cluster / grid synchronization | Larger collective phase boundaries | Hardware cluster or cooperative grid | An unrestricted global barrier in every launch |
| Streams / events | Ordering and completion between submitted operations | Host runtime / execution streams | Serialization of threads inside a kernel |

These categories follow the distinctions in [Modular's coordination guide](https://max.modular.com/gpu/block-and-warp/),
[NVIDIA's synchronization library](https://nvidia.github.io/cccl/unstable/libcudacxx/extended_api/synchronization_primitives.html),
and [CUDA asynchronous execution](https://docs.nvidia.com/cuda/cuda-programming-guide/02-basics/asynchronous-execution.html).

## Mojo standard library

### Atomics and ordering

The versioned [Mojo 1.0.0 Atomic reference](https://mojolang.static.modular.com/1.0.0/docs/std/atomic/atomic/Atomic/)
documents `load`, `store`, `fetch_add`, `fetch_sub`, `compare_exchange`, `max`,
and `min`, with ordering parameters and a synchronization-scope parameter.
Arithmetic and compare-exchange signatures show relaxed defaults on Apple GPU
targets and sequential defaults elsewhere. Specify ordering explicitly for a
portable contract. A type appearing in a generic API is not evidence that every
operation, width, or ordering is supported on every target.

The pinned [atomic implementation](https://github.com/modular/modular/blob/4b0d20f5160137da0b6e9c63503d282cfcea8551/Mojo/stdlib/std/atomic/atomic.mojo)
contains `Ordering`, `fence`, and `Atomic`; operations lower through compiler
atomic operations with ordering and scope attributes. It uses a type parameter
for `Atomic`, whereas the versioned reference uses a dtype parameter. An exchange
helper is private (`_xchg`), so a Larecs public exchange API should not assume a
stable upstream public method with that name. Compiler-interpreter handling is
not evidence of GPU or concurrent host correctness.

### Barriers and specialized synchronization

The [Mojo GPU sync reference](https://mojolang.org/docs/std/gpu/sync/sync/)
lists `barrier`, `syncwarp`, named barriers, `mbarrier_*`, async copy completion,
and AMD scheduling/wait-count controls. Their purposes differ:

- `barrier()` coordinates a block. Its participating threads must reach the
  matching synchronization point; arbitrary divergent entity loops cannot
  assume this condition.
- `syncwarp()` coordinates a subgroup. Mask and memory semantics require
  backend-specific checks.
- `named_barrier` and `named_barrier_arrive` support NVIDIA participant-count
  and split-phase patterns.
- `mbarrier_*` initializes, arrives at, and checks phased shared-memory barriers,
  including expected asynchronous transaction completion on NVIDIA.
- `cp_async_bulk_commit_group` / `cp_async_bulk_wait_group` manage asynchronous
  bulk copy groups on NVIDIA.
- AMD `schedule_barrier` / `schedule_group_barrier` constrain instruction
  scheduling. `s_waitcnt` tracks instruction completion. Neither should be
  treated as a general mutual-exclusion API.

The [Modular guide](https://max.modular.com/gpu/block-and-warp/) presents block
barriers as the common NVIDIA/AMD/Apple operation, and distinguishes raw
synchronization from reductions, broadcasts, and scans that combine coordination
with computation. A reduction can reduce contention on a global atomic counter,
but its participants still need a collective execution contract.

### State semaphores

The [Mojo semaphore reference](https://docs.modular.com/mojo/std/gpu/sync/semaphore/Semaphore/)
describes a shared state variable, a designated thread that loads the state,
`wait(status)`, and `release(status)`. Waiting and release involve block barriers.
This is a group protocol, not a guard that an arbitrary entity-processing thread
can independently acquire and drop.

The [semaphore module](https://docs.modular.com/mojo/std/gpu/sync/semaphore/)
identifies NVIDIA-specific inter-block support. Its terminology must not be
confused with the counting-permit semantics of NVIDIA's `cuda::counting_semaphore`.

## MAX framework

### Low-level GPU synchronization

[MAX `max.gpu.sync`](https://max.modular.com/api/mojo/max/gpu/sync/)
documents barriers, named barriers, memory barriers, semaphores, AMD scheduling
controls, and bulk-copy synchronization. This overlaps the facilities described
by older Mojo GPU pages; the documentation alone does not prove that every
import path is available in MAX 26.5.0.

The pinned [MAX synchronization source](https://github.com/modular/modular/blob/4b0d20f5160137da0b6e9c63503d282cfcea8551/max/mojo/max/gpu/sync/sync.mojo)
provides several concrete qualifications:

- Block barriers have NVIDIA, AMD, and Apple branches.
- NVIDIA subgroup synchronization uses a lane mask; AMD's wave barrier does
  not use that mask. Apple's SIMD-group barrier ignores the mask and uses no
  memory fence. The Apple branch is execution synchronization only.
- Named barriers require NVIDIA. There are 16 hardware slots, indexed 0–15;
  the implementation checks the upper bound despite looser prose in some docs.
- `mbarrier` and bulk-copy operations have NVIDIA-specific paths and reject
  unsupported targets; instruction generation still depends on hardware support.

The pinned [MAX semaphore source](https://github.com/modular/modular/blob/4b0d20f5160137da0b6e9c63503d282cfcea8551/max/mojo/max/gpu/sync/semaphore.mojo)
uses device-scoped acquire loads and release stores around group coordination.
`Semaphore.wait` checks a requested state; it does not atomically claim that
state for one exclusive caller. `NamedBarrierSemaphore` coordinates selected
thread groups and state publication using named barriers. Consequently, directly
renaming either type to `Mutex` or `RwLock` would not establish mutual exclusion.

### Communication signals and collective protocols

[MAX `comm`](https://max.modular.com/api/mojo/comm/)
provides allreduce, allgather, reduce-scatter, broadcast, scatter, and low-level
signals / Lamport protocols for multi-GPU inference, with NVIDIA and AMD targets.

The pinned [communication synchronization source](https://github.com/modular/modular/blob/4b0d20f5160137da0b6e9c63503d282cfcea8551/max/kernels/src/comm/sync.mojo)
implements `Signal` counters for local and peer block progress, initialization,
peer-access helpers, and internal multi-GPU barriers. Different collective
domains receive separate counter banks to prevent their phase histories from
interfering. Release/acquire publication and group barriers appear in these
protocols. These are useful examples of explicit domain identity and generation
tracking, but require the collective's rank, block, memory, and launch assumptions.
They are not a general protected-value API.

### Runtime completion

The pinned [DeviceContext implementation](https://github.com/modular/modular/blob/4b0d20f5160137da0b6e9c63503d282cfcea8551/max/mojo/max/gpu/host/device_context.mojo)
exposes stream synchronization, event creation/recording, and enqueued waits on
events. These support safe transfer completion and dependencies between kernels
or streams. They do not fix races between workers already executing one kernel.

## NVIDIA publications

### CUDA barriers and Cooperative Groups

[CUDA Cooperative Groups](https://docs.nvidia.com/cuda/cuda-programming-guide/04-special-topics/cooperative-groups.html)
supports explicit thread groups, subgroup partitioning, group synchronization,
and collectives. Group synchronization establishes arrival and memory visibility
for that group. Thread-block clusters require compute capability 9.0 or newer.
Whole-grid synchronization requires `cudaLaunchCooperativeKernel`; it is not
valid in an ordinary unconstrained launch. CUDA 13 removed the Cooperative
Groups multi-device launch APIs.

The [CUDA 13.0 grid synchronization documentation](https://docs.nvidia.com/cuda/archive/13.0.0/cuda-c-programming-guide/index.html#grid-synchronization-cg)
also explains sizing a cooperative grid to fit the concurrently resident blocks
using occupancy information. Larecs' thread-count launch cap is not the same as
an occupancy proof or a cooperative launch guarantee.

### Scoped atomics and memory fences

[CUDA memory semantics](https://docs.nvidia.com/cuda/cuda-programming-guide/05-appendices/cuda-cpp-memory-model.html)
separates thread scope from memory ordering. Synchronization must cover the
actual communicating threads. Device scope does not cover CPU threads; system
scope additionally depends on the memory allocation and hardware properties
needed for atomicity. A broad scope alone does not make an arbitrary host
allocation safely accessible from GPU code.

[CUDA language extensions](https://docs.nvidia.com/cuda/cuda-programming-guide/05-appendices/cpp-language-extensions.html#memory-fence-functions)
documents block/device/system fences, `cuda::atomic` and `cuda::atomic_ref`, and
device built-in atomic operations. It recommends the C++ fence API where
possible. Fences order accesses; they do not wait for a second thread or grant
ownership. Publication needs a matching synchronization protocol. `volatile`
is not a substitute for atomic access or a happens-before relationship.

### Latches, semaphores, and CPU compatibility

[libcu++'s synchronization inventory](https://nvidia.github.io/cccl/unstable/libcudacxx/standard_api/synchronization_library.html)
lists atomics, latches, barriers, and semaphores. The
[extended APIs](https://nvidia.github.io/cccl/unstable/libcudacxx/extended_api/synchronization_primitives.html)
include scoped atomics, counting and binary semaphores, and pipeline objects.
A latch represents a single completion phase; barriers support repeated phases.
A binary semaphore can enforce exclusion, but neither type supplies our desired
immutable/mutable borrow interface. The listed standard headers do not include
`mutex` or `shared_mutex`; this is a bounded finding about this inventory, not a
claim that GPU locks cannot be implemented.

[NVIDIA's counting semaphore specification](https://nvidia.github.io/cccl/unstable/libcudacxx/extended_api/synchronization_primitives/counting_semaphore.html)
adds thread scope to the standard counting-semaphore interface. It prohibits
use on Pascal / compute capability 6 or earlier and constrains concurrent CPU/GPU
use to system scope with specified memory/hardware support. This demonstrates
that “usable on CPU and GPU” and “shared concurrently between CPU and GPU” are
separate promises.

### Async barriers, pipelines, and instruction-level mechanisms

[CUDA asynchronous barriers](https://docs.nvidia.com/cuda/cuda-programming-guide/04-special-topics/async-barriers.html)
separate arrival from waiting, allowing independent work between them. They
require initialization and correct arrival counts / phase handling. These are
phase coordination mechanisms, not locks on a variable.

[CUDA pipelines](https://docs.nvidia.com/cuda/cuda-programming-guide/04-special-topics/pipelines.html)
coordinate stages through producer acquisition/commit and consumer wait/release.
They support overlapping asynchronous copies and computation. Warp divergence
can entangle commit/wait sequences, so pipeline operations have participation
rules that a casual lock-like wrapper would hide.

The [PTX ISA](https://docs.nvidia.com/cuda/parallel-thread-execution/index.html#parallel-synchronization-and-communication-instructions-mbarrier)
specifies barrier instructions, scoped ordering, and memory-resident `mbarrier`
state. Hardware named-barrier slots and shared-memory `mbarrier` objects have
different resource limits. The latter track arrivals and asynchronous completion;
initialization, phase, alignment, and instruction-specific target requirements
must be respected.

[CUTLASS synchronization primitives](https://docs.nvidia.com/cutlass/latest/media/docs/cpp/pipeline.html)
show higher-level producer/consumer pipelines built around full/empty buffer
states. This is an implementation model for specialized tiled kernels, rather
than a general solution to concurrent access to an ECS dictionary.

### Runtime ordering and progress hazards

[CUDA streams and events](https://docs.nvidia.com/cuda/cuda-programming-guide/02-basics/asynchronous-execution.html)
order submitted work and establish completion dependencies. Ordered launches
are a practical boundary for global phases without an in-kernel grid barrier.
Different streams require explicit dependency handling when sharing results.

[NVIDIA's scheduling discussion](https://docs.nvidia.com/cuda/cuda-programming-guide/03-advanced/advanced-kernel-programming.html)
specifically describes lock-related divergence deadlocks before compute
capability 7.0, and the independent thread scheduling introduced from 7.0.
That change improves flexibility; it does not certify every arbitrary lock
algorithm. Residency and dependency cycles still need examination. Rejecting
portable blocking acquisition in the first Larecs API is our conservative design
inference, not a statement that current NVIDIA GPUs cannot run blocking protocols.

## Implications for Larecs

These are recommendations based on the evidence above, not new accepted requirements.

1. Build atomic scalar access on `std.atomic`, with explicit order and scope.
   Validate the exact locked release, integer widths, operations, and backend
   lowering before promising a portable operation set.
2. Implement reader/writer ownership as a separate layer: shared read guards,
   exclusive write guards, stable storage identity, and confined references.
   Existing semaphores do not enforce this contract automatically.
3. Keep the initial shared guard API nonblocking. Record contention rather than
   silently losing required updates; progress and retry policy belong in the
   execution design.
4. Map every byte of protected collection storage to a consistent domain. Use
   elements/chunks/stripes for fixed arrays and frozen dictionary values first.
   Concurrent dictionary structure mutation needs a separate container protocol.
5. Keep group barriers / reductions in an explicitly collective API. Ordinary
   grid-stride entity iteration allows unequal loop lengths, including idle
   lanes; it cannot implicitly guarantee barrier participation.
6. Use ordered execution boundaries for global phases first. Cluster, cooperative
   grid, async pipeline, and multi-GPU paths can be specialized extensions.
7. Separate backend capability from API spelling. In particular, do not assume
   `syncwarp` is a portable memory-publication primitive, or interpret device-wide
   state as a promise of lock ownership or scheduling progress.

The validation backlog remains in the
[single roadmap](../../roadmap.md#kernel-memory-synchronization). Implementation of
decision 0016 must pass release-specific compile probes, origin-confinement
experiments, concurrency tests, and actual CPU/NVIDIA/AMD/Apple evidence for each
claimed backend. None of the source inventories by itself establishes those results.
