# Documentation review and proposed structure

Organize Larecs around a short working simulation, focused task guides, explicit
API contracts, and a separate architecture and development path. Keep the
navigation task-based: **Start**, **Guides**, **Reference**, **Architecture**,
and **Development**. Readers should find the appropriate depth through these
names and links, without an audience-selection page.

This proposal covers the README, all handwritten site pages, API generation and
templates, public API examples and selected contract docstrings, and the design
index and architecture overview. Findings distinguish incorrect statements from
missing explanations and presentation problems. It is a source audit, not a
claim that every generated page or external link has been verified.

The implementation baseline includes the contiguous PR chain
[#212](https://github.com/larecs/larecs/pull/212),
[#215](https://github.com/larecs/larecs/pull/215),
[#216](https://github.com/larecs/larecs/pull/216), and
[#217](https://github.com/larecs/larecs/pull/217).
Examples must use `backend=ExecutionBackend.HOST/DEVICE`, with HOST the default
and no automatic DEVICE fallback. Batch execution uses `EntitySelection`;
lower-level storage iteration uses `LockedEntityRange`.

## Incorrect and misleading content

Locations below refer to source paths relative to the repository root. P1
findings affect working examples or the API contract; P2 findings affect
explanation, navigation, or precision.

| ID | Priority and location | Finding and correction |
| --- | --- | --- |
| E01 | P1 · `docs/src/_index.md:20` | Advertises a public `vectorize`-like SIMD API. `guide/vectorization.md` explicitly says there is no SIMD-batch iteration interface, and the old SIMD `apply` implementation is commented out in `host_storage.mojo`. Remove this feature claim; describe column storage and kernel execution separately from explicit vectorization. |
| E02 | P1 · `docs/src/guide/entities_components_world.md:86` | Says only trivial components are supported and owning components may be supported later. `ComponentType = Copyable & Deinitable`, typed column lifecycles, and `test/host_storage_lifecycle_test.mojo` support nontrivial host components now. Explain host, threaded-host, and device constraints independently. |
| E03 | P1 · `README.md:225` | Applies the component `TrivialRegisterPassable` requirement to resources too. Ordinary resource eligibility uses recursive representation checks, while owning sources can supply read-only adapters. Match `resource.mojo`, `resource_representation.mojo`, and the resource guide; declaring the trait alone is not the general resource rule. |
| E04 | P2 · `docs/src/guide/resources.md:155` | Says resources can be complex “in contrast to components.” Both can own heap data on the sequential host. Describe the actual distinction: resources are one value per type per world and have different kernel-transfer rules. |
| E05 | P2 · `docs/src/guide/resources.md:216` | Says the host invokes a kernel once per archetype. Partitions produce multiple physical stores per logical archetype; selections can identify partial ranges; threaded execution splits ranges into chunks. State invocation granularity per execution mode and keep side effects inside the row loop where possible. The same qualification is needed in the draft vectorization page and closure-overload docstring in `system.mojo`. |
| E06 | P2 · `docs/src/guide/resources.md:282` | Unconditionally says samples are uploaded every invocation. Later sections correctly document opt-in device-copy reuse skipping `prepare_device`. Qualify this as the default behavior and link to the reuse contract. |
| E07 | P1 · `docs/src/guide/queries_iteration.md:175` | Refers to the `move_entities` kernel “declared above,” but its definition and filter are inside a `hide=true` block. Readers cannot see the function being explained. Show the kernel before its call. |
| E08 | P1 · `docs/src/guide/systems_scheduler.md:54` | The main visible example uses `Position` and `Velocity`, but their definitions are hidden later. Earlier examples also alternate `Velocity.x/y` and `Velocity.dx/dy`. Provide one complete visible example with consistent field names and reuse it. |
| E09 | P1 · `docs/src/guide/adding_and_removing_entities.md:71` | Calls `created.run[place_batch]()` while `place_batch` is defined only in hidden setup. Its `row.idx` positioning also needs an explanation that indices restart per selected host range. Show the function and bound the example's indexing claim. |
| E10 | P1 · `src/larecs/host_storage.mojo:617,717,1498` | API examples use `world.add_entity`, `world.add_entities`, and `world.replace`; these operations live on `world.storage`. Examples also introduce variables with bare assignment and omit a runnable entry point. Correct the API paths and Mojo syntax, then compile the exact examples. This is a content defect independent of Modo's wrapper limitations. |
| E11 | P1 · `src/larecs/scheduler.mojo:77` | The scheduler example introduces `scheduler` without `var` in a non-global doctest block. Convert it to a complete runnable example with `def main() raises`. |
| E12 | P2 · `docs/src/guide/queries_iteration.md:196` | Links to `spatial_clustering.md#cluster-local-partition-blocks`, but the heading is “Growable cluster-local partitions.” Use the actual generated heading ID and check it in the built site. |
| E13 | P2 · guide links to `../../design/...` | Decisions and research are outside Modo's `input: docs/src` tree. Links from published guides to these relative `.md` paths have no corresponding generated design pages in this pipeline. Either publish the architecture/development material with resolved site links or link explicitly to repository files. Includes the selection migration, spatial decision, and resource-view probe links. |
| E14 | P2 · `docs/design/architecture.md:47` | Calls cluster-local partitions an undecided alternative. Decision 0006 is accepted and 0014 implements growable stores, as the same overview's next section acknowledges. Describe the current two placement modes and move historical alternatives into the decisions. |
| E15 | P2 · `docs/src/guide/benchmarks.md:177` | Attributes 256 MB of cache to GitHub CI hardware and predicts Larecs will beat AoS on most laptop/desktop configurations. The page provides no identified measurement environment supporting that generalization. Record the actual run's hardware, compiler, commit and method; remove the blanket prediction. Preserve the more carefully qualified evidence elsewhere on this page. |
| E16 | P2 · `docs/src/guide/adding_and_removing_entities.md:130` | The entity-batch tip says “adding and removing many components.” Change the subject to entities and qualify performance by operation/workload rather than promising a universal significant improvement. |
| E17 | P2 · `src/larecs/filter.mojo:155,172` | `includes` and `excludes` say they return “whether” a type is present, but return an index or `-1`. Describe index lookup explicitly; truth-testing the result would invert the meaning for index zero and absent entries. |
| E18 | P2 · `src/larecs/resource.mojo:145` and `component.mojo:66` | `Resources.__len__` describes component types and a filter; `Components.__len__` also refers to a filter. Describe the count of declared resource/component types in the list. |
| E19 | P2 · `src/larecs/pool.mojo:19` | Contains the malformed reference `https:#skypjack.github.io/...`. Restore `https://` and a normal descriptive link. |
| E20 | P1 · `src/larecs/__init__.mojo`, `Exports:` | The manual export list and actual root imports disagree. It lists `Replacer`, `ComponentManager`, device storages, `EntityAccessor`, and `BitPool` without corresponding root imports, while omitting root-imported `Components`, `EntitySelection`, `EntityRange`, and resource adapter types. With `exports: true`, this also makes API placement and root links suspect. Derive canonical public paths from the intended export surface and validate generated targets. Do not imply every documented module symbol can be imported from `larecs`. |
| E21 | P2 · `docs/src/guide/systems_scheduler.md:10` | Says systems can be added or removed as required, but `Scheduler` exposes registration, not a system-removal method. Describe registration-order execution without promising runtime removal. |

## Documentation coverage and tooling problems

| ID | Location | Problem and proposed treatment |
| --- | --- | --- |
| G01 | Installation guide and README | Manual precompilation is presented before a complete dependency environment. The README identifies MAX and mojo-tracy, but the guide does not establish them, supported platforms, compiler compatibility, or a successful smoke run. Lead with a repository-pinned Pixi path and a minimal verified external-project recipe; retain `.mojoc` and source inclusion as explicit alternatives. Do not invent a published install channel. |
| G02 | Guide ordering | Readers reach systems only after storage mutations, queries, and resources; the earlier chapters repeatedly refer forward to systems. Introduce a working scheduler/system/kernel loop immediately, then explain each operation through it. |
| G03 | Resources guide | A basic resource tutorial expands into adapter implementation, unsafe-origin rationale, transfer caching, concurrency contracts, and revisions. Split these into ordinary resources, portable resources, adapter reference, copy reuse, and architecture details. Keep reference-validity obligations next to any unsafe access. |
| G04 | Systems guide | Scheduling, kernel access, threading, lexical closures, explicit captures, device requirements, and transfer reuse share one long page. Give execution and captures their own guides and a compact support matrix. Threaded kernels do not imply concurrent systems. |
| G05 | Benchmark guide | Roughly 600 lines mix application tuning, regression-check implementation, historical layouts, raw results, and compilation evidence. Separate performance guidance, benchmark methodology, regression-check development, and dated measurement reports. Retain historical evidence with its original layout and revision labels. |
| G06 | Queries and mutation guides | Query cursors, row accessors, stable handles, selections, and storage ranges are introduced across pages without a single comparison. Explain which can be copied, which own locks, what survives exhaustion, and which support mutation/execution. A structural lock is not a cross-thread mutex. |
| G07 | Filters and execution | `include`, `read`, and `write` have important access and transfer semantics but no focused guide. Show `get` versus `set`, upload/download directions, exclusive/excluded matching, and why a write-only field must be initialized for every processed row. Separate component and resource permissions. |
| G08 | Synchronization | The guide correctly distinguishes standalone primitives from unfinished kernel bindings, but appears before the execution model and has no practical route from a shared kernel write to an available binding. Move it after execution and preserve that limitation prominently; never present planned `context.sync` APIs as callable. |
| G09 | Homepage, README, package docstring | Three overlapping introductions and large duplicated examples drift independently. Use one checked example, a short homepage with entry links, and a README that links to it. Link Larecs resources to Larecs documentation rather than Arche's resource guide. |
| G10 | `docs/templates/overload.md` | Every overload's description and argument/error contract is collapsed by default. The template explicitly renders description/parameters/arguments/returns/raises but no dedicated Constraints section. Show the main contract immediately and verify that constraints and notes survive rendering. Keep expanded secondary detail optional. |
| G11 | `docs/site/layouts/shortcodes/api.html` | API URLs are manufactured by replacing dots with `#` under a hard-coded `/larecs/larecs/` prefix, and every link opens a new tab. This cannot validate canonical exports or module-qualified targets and is tied to one deployment path. Resolve symbols through a generated symbol map; use ordinary same-tab links. Actual target coverage requires a successful site build. |
| G12 | `modo.yaml`, doctest runner | `strict: false` permits documentation warnings. The runner excludes eight named source-doctest files and succeeds when the generated directory/files are missing. Some exclusions name removed `Query` examples. Inventory current extracted tests, distinguish compile failures from generator limitations, and fail CI on unexpectedly missing examples. Introduce strict coverage incrementally after existing warnings are fixed. |
| G13 | `mojo doc` diagnostics | JSON generation succeeds but warns about `indices` in `_TypeChecks._name_indices` and `data` in `DeviceComponentStorage.copy_to_host`. Both are `out` results documented under Args. Use the compiler-supported result documentation form and retain the actual behavior description. |
| G14 | Local site build | `pixi run build-docs` fails on this Apple Silicon environment with `OSError: [Errno 86] Bad CPU type in executable` for pymodo's `modo_macos`. This blocks generated-link, layout, and extracted-doctest verification here; it does not establish that the Linux publishing job fails. Make native macOS generation reproducible or document a verified generation environment. |
| G15 | Version and status boundaries | Beta breaking changes, experimental threading/device-copy reuse, unfinished synchronization bindings, and historical decisions need a single navigable status and migration reference. An accepted design must not be presented as proof that every capability is implemented or hardware-validated. |

## Proposed navigation and page content

Use one movement simulation with `Position`, `Velocity.dx/dy`, a `Time.delta`
resource, and a `Move` system. Start with a sequential host run whose final
position is asserted. Add selection, device, and threading variants without
changing names or silently executing multiple variants as one application step.
Every guide should end at a concrete working result and link to the precise
reference contract it uses.

### Start

| Page | Content and outcome |
| --- | --- |
| Overview | Explain entities as identities, components as per-entity data, resources as world data, systems as scheduled application logic, and kernels as filtered row work. Show the whole execution chain in a compact diagram and link to the first simulation. |
| Install and verify | Supported platforms and pinned toolchain; obtain dependencies; source inclusion versus precompiled package; external-project smoke run; editor configuration; dependency/linker troubleshooting. Finish with a compiled import and one entity lookup. |
| Your first simulation | One complete program: define components and time, create a world, seed entities, register Move, run steps, assert the result. Explain only the syntax required to read it, including `SystemContext[...]`, `context.world[]`, and ownership transfer into Scheduler. |

### Guides

| Page | Content and outcome |
| --- | --- |
| Model entities and components | Choose component boundaries, zero-field tags, one component per type, compile-time world type packs, stable entity identity and `is_alive`, host ownership requirements, and when a value belongs in a resource. Reacquire components after structural changes. |
| Organize systems and time | Registration order and initialize/update/finalize; persistent system state; fixed versus application-controlled stepping; shared time resources; direct setup versus scheduled application changes. Explain actual error propagation and the absence of guaranteed finalization after an update error. |
| Find and inspect entities | Include/exclude/exact filters; read-only queries; `get`, `has`, checked `unsafe_get`, and `get_entity`; immutable reads; cursor copies, moves, lock lifetime, and counting costs. End with a filtered diagnostic report. |
| Write kernels and declare access | KernelContext and row accessors; read/read-write/write-only components; `get` and `set`; filters as membership plus access declarations. Show a read-only velocity and mutable position, then a write-only output kernel. Explain local indices and prohibit treating them as stable entity IDs. |
| Create and change batches | Single-entity storage changes, SystemContext batch methods, exact modified-row membership, reusable selection execution, in-place add/remove/replace, intersections, empty selections, and `with` cleanup. Finish with spawn → initialize → run → release. Explain low-level storage ranges only as a linked alternative. |
| Share state with resources | Add/read/get/set/remove, one source per type, missing/duplicate handling, multi-resource failure behavior, explicit kernel permissions, and safe changes between runs. Start with `Resources().read[Time]()` so the example also teaches the threading-compatible choice. |
| Execute on a device | Explicit ExecutionBackend selection, actual accelerator/toolchain requirements, no fallback, component eligibility, resource eligibility, synchronous transfers and copy-back, empty matches, and host/device parity checking. Explain when transfer cost can dominate work. |
| Pass local values to kernels | Lexical host closures versus explicit ReadCapture/MutCapture bindings; binding types and origins; shared mutable outputs; empty matches; no lexical device capture or implicit object-graph transfer. Show a single-writer result and a per-row component-output alternative. |
| Use portable resources | Start with BufferResource/ReadBuffer, then one complete custom Grid owner/view/adapter. Explain source-type lookup returning a view, target-local pointers, validation, leases, read-only access, and concurrent-read obligations. Put the full adapter protocol in Reference. |
| Run threaded host work | Configure ThreadedExecutionConfig; choose `threaded=True`; explain thresholds, whole-range fallback, thin kernels, plain components, read-only resources/views, no captures, join semantics, and chunk-local side effects. Demonstrate the same result as the sequential host path. |
| Maintain spatial locality | Explain a measured locality problem, classifier filters, bounded cell/Morton helpers, explicit maintenance and dirty tracking, stable IDs, row reordering versus growable partitions, staging, and exact cluster selection. Make clear that a cluster key is not an exact neighbor query. |
| Reuse device copies | Enable the experimental per-world option only after a correct device example. Explain resource/column revisions, mutable get versus read, escaped-reference invalidation, pack-offset changes, failures, world copies, and disabling reuse. Separate reused allocations from reused data. |
| Coordinate shared writes | Available atomics and scoped guards; access results and Busy handling; scalar/order/backend restrictions; single-writer and multi-pass reductions; current lack of automatic kernel bindings. Avoid suggesting that ordinary mutable resources automatically gain synchronization. |
| Measure and tune a simulation | Establish correctness first; identify dominant systems; measure complete steps and kernel/transfer/maintenance time separately; compare target choices and spatial cadence; run Tracy; distinguish explicit SIMD from compiler optimization. Link reproducible benchmark methodology and scoped results. |
| Diagnose common failures | Unknown/missing components/resources, duplicate declarations, locked structural changes, exhausted lock slots, dirty cluster selections, invalid device representations, rejected captures/threaded inputs, unavailable device, stale copies, and platform toolchain failures. Map each to a minimal cause and fix. |

### Reference

Keep a curated topic index above generated symbol pages. Each topic below gets
a short contract introduction, an example link, and a symbol list; signatures,
overloads, parameter constraints, and docstrings remain generated from source.

| Reference page | Contract and symbols |
| --- | --- |
| World and entity identity | World construction/ownership/copying; component universe; Entity generation, world locality, zero handle, recycling and wraparound limits; `is_alive`; read versus mutable lookup. |
| Storage operations | HostStorage single and batch creation/deletion, get/read/has/set/add/remove/replace/apply, Replacer, runtime filters, count validity, returned ranges, lock restrictions, failure effects and reference invalidation. |
| Filters and component access | Filter and Components; include/read/write/exclude/exclusive; filter index results; query row accessors versus kernel EntityAccessor; get/set/unsafe_get and compile-time versus runtime checks. |
| Queries, ranges and selections | LockedEntityRange, EntityRange, EntitySelection and factories. Comparison of membership, mutability, copyability, scope, exhaustion, release, structural authorization, repeated execution, and index meaning. |
| Systems and execution | System lifecycle, Scheduler, SystemContext, KernelContext, ExecutionBackend and ThreadedExecutionConfig; all run overloads, defaults, unavailable backend behavior, invocation granularity, ordering, synchronous completion and empty matches. |
| Resources and adapters | ResourceStorage, Resources and ResourceType; permission builders, source/view distinction, BufferResource/ReadBuffer, DevicePassableResource, ResourceAdapter and ResourceDeviceCache. Validation order, reserved slots, lifetime and transfer responsibilities. |
| Captures | Captures, ReadCapture, MutCapture, read_capture and mut_capture; slot ordering, matching types, borrow restrictions, target limitations and copy-back semantics. |
| Spatial APIs | SpatialClassifier, registration, grid_cell/morton_key_3d bounds, maintenance/invalidation, partition mode and select_cluster; exact errors, dirty-state rules and ordering guarantees. |
| Synchronization | AtomicValue/AtomicView, Synchronized/SyncView, CompareExchangeResult/TryAccess and returned guards; operations, orderings, scalar constraints, contention, confinement, unsupported operations and unsafe-constructor obligations. |
| Ownership and execution compatibility | One cross-cutting table for sequential host, threaded host, device and portable views: components, resources, captures, mutation, concurrency and reference validity. Link to defining contracts rather than duplicating all details. |
| Errors and recovery | LarecsError and variants, ordinary Error paths, compile-time rejections, fallible preparation, operations with partial progress, failed device invocations, and fatal lifecycle violations. State rollback only where implemented. |
| Releases and migrations | Release/compiler compatibility, public versus experimental guarantees, changelog, and beta migrations: World.storage, systems/contexts, on_gpu → on_device → backend, and iterators → storage ranges/selections. Link historical ADRs without teaching old spellings as current APIs. |

### Architecture

| Page | Content and evidence |
| --- | --- |
| Execution and ownership map | Scheduler → system → SystemContext → selection/run → KernelContext; World ownership of host/device storage and resources. Include leases, structural locks and synchronous run boundaries; link actual modules and tests. |
| Archetypes and entity locations | Logical composition versus physical stores; SoA component columns with AoS fields inside each component; entity ID/generation lookup; graph transitions; growth, swap-removal, typed copy/move/destruction and location repair. |
| Query and selection internals | Filter masks, store discovery, shared immutable range metadata, independent copy cursors/locks, noncopyable exact selections, scoped ownership, mutation authorization and bounded migration. |
| Host and device execution | Shared preparation, whole-store and selected host ranges, threaded chunks, device packing, capped grid-stride iteration, permissions and scatter copy-back. Explain granularity changes outside the entity loop. |
| Resource binding and transfers | Owning source versus kernel view, type identity, plain-value validation, adapter preparation, leases/staging, allocation capacity, revisions, copy reuse and failure cleanup. Put unsafe-origin rationale here. |
| Spatial storage and maintenance | Dirty identity queues, full rebuilds, prepare-before-move error guarantees, typed permutations, growable cluster stores, staging and directory costs. Distinguish locality from spatial indexing. |
| Synchronization internals | Protection identity, atomic state encoding, acquire/release guards, target-local scope and Apple limitations; implementation status of binding and collection extensions. |
| Decisions | Publish the existing numbered ADR index with status/supersession metadata. Preserve historical rationale and proposed/rejected work; link each current concept to the decisions governing it. |

### Development

| Page | Content and outcome |
| --- | --- |
| Build and test | Environment setup; full/focused tests; formatting; source and package smoke tests; compile-contract checks; GPU markers and SDK workaround; distinguish compiled/skipped tests from actual device coverage. |
| Change an ECS contract | Requirements, relevant ADRs, glossary, implementation/tests/guides that must change together, lifecycle invariants, performance evidence and compatibility policy. Preserve existing design-record conventions. |
| Build and maintain documentation | JSON → API conversion → Hugo pipeline; source/generated boundaries; example extraction and execution; figure rendering; symbol resolution; link/anchor checks; warning policy and publishing. |
| Benchmark methodology | Focused drivers, paired baselines, same compiler/runner, timing boundaries, warmup, checksums, uncertainty, compilation cost and hardware evidence. Link reports without treating measurements as portable constants. |
| Performance regression checks | Current case manifest, baseline selection/bootstrap, confirmation thresholds, artifact schema, approximate runtime budget, failure triage and justified policy changes. |
| Research and measurement reports | Existing investigations and dated benchmark evidence grouped by subject and implementation revision. Separate observations from adopted contracts and current performance guarantees. |

Keep `docs/design/decisions/` and research paths stable in the repository. Publish
them under Architecture/Development using explicit content mappings or a
deterministic copy step. Keep the roadmap as the only task-priority list and the
changelog as release history. Do not turn the new page outline into ADRs.

## Thesis material to adapt

The sources are `master-thesis/thesis.typ` and `master-thesis/figs.typ` in the
author's thesis repository. Use their explanations and visual language, while
checking every API name and layout detail against this stack.

| Thesis section or figure function | Documentation use and adaptation |
| --- | --- |
| Background: Data-oriented design; `aos-soa-memory` | Explain access patterns and cache lines in the performance/architecture path. Identify Larecs's actual unit of column storage: one component struct, not a separate column for every scalar field. |
| Entities, components and systems; `ecs-entities-components`, `ecs-systems` | Overview and first simulation: show identities, component composition and which system touches which data. Keep the first diagram free of allocator/transfer machinery. |
| Archetype-based storage; `archetype-add-component` | Explain structural versus value changes in the batch guide; use the detailed form in storage architecture. Show moved rows and repaired entity locations without implying persistent row indices. |
| Architecture; `larecs-architecture` | Redraw the pre-thesis architecture for the current World, SystemContext, EntitySelection and KernelContext boundaries; add device storage/resources and the threaded execution path. The thesis caption explicitly describes an older architecture. |
| `archetype-memory` | Storage architecture: header, component slots and columns. Recheck current allocation/column representation and zero-component handling; avoid copying historical NULL-slot or layout assumptions as guarantees. |
| Kernel interface/work mapping; `host-execution`, `threaded-host-execution`, `device-grid-stride` | Execution guide and architecture: one kernel, three invocation mappings. Add exact selected subranges, current physical stores and chunk-local indices. Keep block-size and launch-cap arithmetic in architecture. |
| Component transfer; `device-memory` | Device guide: pack readable component spans, launch, scatter writable results. Add write-only outputs, selected ranges and the distinction between a logical archetype and a physical store. |
| `device-copy-reuse` | Copy-reuse guide: first upload, unchanged reuse, tracked write/invalidation, next upload. Distinguish valid data from retained allocation capacity. |
| Resource transfer explanation | Portable-resource guide and architecture: source → adapter → target-local view. The thesis includes mutable-adapter work from another branch; this stack's adapted resources are read-only. Do not import that future surface. |
| `spatial-z-order`, `spatial-ordering`, `spatial-grouping` | Spatial guide and architecture: contrast key order with persistent clusters. Adapt Tree-D classifier details to a small generic position example and current growable stores. |
| Performance and evaluation methodology | Benchmark methodology and tuning: validate equal work, include preparation/transfer/maintenance in complete-step comparisons, distinguish kernel speedup from application speedup, and report uncertainty. Keep Tree-D outcomes as attributed case-study evidence. |

The thesis's baseline query and entity examples use older `world.query` and
direct World mutations, and its heterogeneous examples use `on_device` rather
than ExecutionBackend. Adapt the conceptual sequence, not the listings verbatim.
Avoid importing its entire GPU background or Tree-D-specific light/leaf data
structures into the introductory path.

Export adapted figures as SVG with a consistent palette, legible labels at
article width, light/dark readability, descriptive captions and alt text. Keep
reproducible Typst wrappers in the docs assets workflow and record the originating
figure function. Do not require a checkout of the full thesis to build the docs.

## API documentation overhaul

Retain `mojo doc` as the signature source. First repair the symbol surface,
examples, links and rendering in the existing Modo/Hugo pipeline; replacing the
site generator alone would preserve the current contract errors.

1. Define canonical public import paths from the actual root exports and
   intentionally supported module APIs. Automatically check the declared export
   list against those paths. Put implementation utilities behind an internals
   index rather than making a flat list of all modules the main API entry point.
2. Generate a symbol map with canonical paths, aliases, anchors and source
   locations. Resolve guide shortcodes against it; fail on unknown symbols.
   Pin source links to the documented revision, instead of always `main`.
3. Give every type a readable declaration, role, construction example, method
   index, relevant traits and supported targets. Give each operation its common
   call form, overload differences, compile-time constraints, arguments/results,
   errors and observable failure effects, ownership/invalidation rules, and
   links to a task guide. Label experimental APIs at their entry points.
4. Keep the main description and essential contract expanded. Collapse only
   secondary overload detail and implementation rationale. Render Constraints
   and notes explicitly; confirm search indexes the material readers need.
5. Establish one runnable example source per scenario. Extract or include the
   same visible code in guides and API pages; keep testing assertions visible
   when they explain the outcome. Hidden setup must never contain the concept
   being taught. Compile host examples, compile negative examples against their
   intended diagnostics, and separately record actual device execution.
6. Treat missing generated examples, unresolved links/anchors, export drift and
   new documentation warnings as failures. Retire skip entries as examples or
   tooling are repaired. Keep a small end-to-end fixture covering a root symbol,
   module-only symbol, overloaded method, Constraints section and source link.
7. Evaluate replacing Modo only if native generation, current Mojo extraction,
   symbol resolution or contract rendering cannot be made reliable. Require the
   same fixture, redirect coverage, search and reproducible builds before a
   switch. Retain Hugo unless evidence identifies a separate site limitation.

## Migration and review order

1. Repair misleading contracts and visible examples first: E01–E11, E17–E21.
   Establish the checked movement example and compatibility reference before
   duplicating any more examples.
2. Build Start and the core guides: model → inspect → kernel → batches →
   resources. Move systems/time into the early learning path. Add aliases or
   redirects for existing guide URLs and preserve useful incoming anchors.
3. Extract device execution, captures, portable resources, threading, spatial
   maintenance, copy reuse and synchronization from the long existing pages.
   Use the reference contracts to avoid repeated restrictions drifting apart.
4. Publish Architecture and Development from the durable design material;
   repair the stale architecture summary and move historical measurements out
   of the general performance guide. Resolve site/repository links explicitly.
5. Improve generated API pages and the example/link gates. Validate old URLs,
   root/module symbol resolution, long signatures, search, mobile readability
   and figure contrast before publishing the new navigation.

These are proposed content batches, not a change to release priorities. Track
accepted work in the existing roadmap. The requested deliverable is this audit
and page plan; the public documentation rewrite is a subsequent implementation.

## Verification evidence

Package precompilation and `mojo doc` JSON generation succeed on the combined
stack, with the two docstring warnings recorded in G13. The restacking checks
passed backend and iteration compile-contract probes plus 37 tests across
`execution_backend_test.mojo`, `world_entity_iterator_test.mojo`, and
`entity_selection_test.mojo`. CPU execution tests also passed while integrating
the lower layers. These checks validate integration, not every documentation
example.

The combined stack also passes all positive, negative and intentional-exclusion
cases in `test/check_struct_constraints.py`.

The full documentation build fails before generation with the local Modo
architecture error in G14. Rendered layout, exact generated API targets,
site-wide link completeness and all extracted examples therefore still need a
successful generator run. No figures have been copied or public pages rewritten
as part of this proposal.
