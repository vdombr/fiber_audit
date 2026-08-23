# Changelog

## Unreleased

## 0.3.1 (2026-08-23)

### Added

- Added a lifecycle-owned operation-liveness monitor with strict policy transport,
  explicit active/disabled/unsupported states, and bounded long-active
  start/completion evidence independent of scheduler-heartbeat stalls.
- Added shared operation semantics and five Boolean/nil scheduler-classification
  measurements to targeted operations, watchdog overlaps, and long-active events.
- Expanded the bounded scheduler semantic matrix for Process wait variants,
  coordination hooks, localhost address resolution, and Ruby 4 IO-close
  interruption; added a local measurement-only runtime probe benchmark.

### Changed

- Scheduler snapshot failures now remain `nil`/unknown in JSONL schema 1.0 rather
  than asserting false state.
- FA1006 keeps rule/operation identity while distinguishing socket allocation,
  endpoint setup, local connection, and unknown subclass constructor semantics.
- FA1004 now reports medium severity without execution-context escalation and
  describes possible shared-state exposure without claiming request leakage.
- Documented the tested support contract as CRuby 3.3, 3.4, and 4.0 on Ubuntu
  Linux; the gem installation requirement remains Ruby 3.3 or newer.

### Fixed

- Corrected scheduler snapshots to preserve the actual `Fiber#blocking?` Boolean
  instead of converting both blocking and non-blocking Fibers to true.

## 0.3.0 (2026-08-12)

### Changed

- Reframed static rules as scheduler-cooperation requirements. Advisory rules no
  longer escalate solely because they appear in request-like execution contexts.
- Split FA1001 under its existing rule ID into subprocess creation, replacement,
  waiting, detach, and stream lifecycle semantics; added Process `spawn`, `exec`,
  `wait`, `wait2`, `waitpid`, `waitpid2`, and `Process::Status.wait` coverage.
- Corrected FA1004 to report only true Thread variables. `Thread.current[]` and
  `Thread.current[]=` are Fiber-local and are no longer static or runtime findings.
- Propagated Rails/runtime execution context into child Fibers through immutable
  Ruby Fiber storage, with explicit current-Fiber `clear!`/`reset!` behavior.
- Added scheduler presence, blocking-Fiber state, and optional scheduler-hook
  capability measurements to targeted operation events.
- Added bounded `scheduler_stall_operation_overlap` JSONL 1.0 events. They record
  temporal overlap between a watchdog stall and active operations, not causality.
- Reconciled scheduler observer state only after `Fiber.set_scheduler` accepts a
  change, so rejected replacement attempts preserve the previous observation.
- Added Ruby 4.0 to the required CI matrix and executable local scheduler-semantic
  reproductions under `script/scheduler-semantics`, including Ruby 4's
  `fiber_interrupt` scheduler protocol hook.

## 0.2.1 (2026-08-12)

### Fixed

- Rails 8 and Zeitwerk compatibility during runtime boot: avoid reentrant
  application initialization and premature constant autoloads, preserve
  Zeitwerk directory autoload semantics, and avoid duplicate insertion into a
  copied or frozen middleware stack.
- Install the runtime context middleware at the outer edge of the Rails stack so
  application middleware operations are classified as `middleware`.

## 0.2.0 (2026-08-12)

### Added

- Foundational runtime event, session, safety-policy, redaction, and JSONL
  contracts for the observational runtime auditor.
- An explicit, bounded, thread-safe runtime session recorder with injected
  clocks and sampling, exact drop accounting, crash-tolerant JSONL writes, and
  fail-open safety.
- `fiber-audit runtime -- COMMAND` with strict activation settings, shell-free
  process supervision, signal forwarding, status preservation, process-local
  JSONL sessions, and fork-safe recorder rebinding.
- An opt-in scheduler watchdog with explicit disabled/absent/active/unsupported
  states, scheduler-owned monotonic heartbeats, one bounded start/completion pair
  per stall, privacy-safe project frame evidence, and a process-local active
  operation registry.
- Targeted FA1001–FA1007 runtime probes with monotonic timing, conservative
  project callsites, active-operation overlap, strict recursion protection, late
  standard-library installation, and no captured commands, URLs, addresses,
  payloads, exception data, or thread-local values.
- Rails runtime execution-context detection with bounded, PID-aware fiber-local
  context stack and process-local Rails integration. Hooks into Rack middleware,
  ActionController, ActiveJob, and ActionCable boundaries with inert wrappers
  after deactivation or fork. Snapshots context at probe observation start and
  propagates through active operations and events while preserving JSONL schema
  1.0, privacy requirements, and lifecycle ownership. Static/runtime correlation
  remains future work.

## 0.1.0 (2026-08-02)

First static-only release of FiberAudit. Requires Ruby 3.3 or newer.

### Added

- Rubydex-backed semantic indexing behind a FiberAudit-owned adapter.
- Prism call-site extraction with conservative receiver inference and stable,
  project-relative fingerprints.
- Rails-aware execution contexts for requests, middleware, callbacks, views,
  jobs, WebSockets, boot, tests, and Rake tasks.
- Seven static rules:
  - FA1001 blocking subprocess operations
  - FA1002 thread waits
  - FA1003 thread-oriented synchronization
  - FA1004 thread-local state
  - FA1005 explicit `IO.select`
  - FA1006 direct sockets
  - FA1007 synchronous request-path HTTP
- Deterministic text and JSON reports using schema version 1.0.
- Inline and YAML suppressions with mandatory reasons.
- Project detection, per-rule configuration, minimum-severity filtering, and
  CI-friendly exit codes.
- `static`, `list-rules`, `explain`, and `version` CLI commands.

### Scope

Version 0.1.0 does not perform runtime analysis and never emits unconditional
`PASS`. Every report states that PASS cannot be granted without runtime
coverage.
