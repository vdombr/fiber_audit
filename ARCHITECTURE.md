# FiberAudit Architecture

FiberAudit audits Ruby and Rails applications for operations that may require cooperation from a Fiber scheduler. It publishes static hypotheses and bounded runtime evidence, but it does **not** prove that an application is fiber-safe and never emits an unconditional `PASS`.

> **Repository status:** The static pipeline, FA1001–FA1008, explicit runtime probes, Rails execution context, invocation-aware scheduler evidence, scheduler watchdog, operation-liveness monitor, opt-in synchronization graph, and opt-in parent process-progress monitor are implemented. Combined static/runtime reporting remains future work.

The gem installation requirement is Ruby `>= 3.3`. The tested platform contract is CRuby 3.3, 3.4, and 4.0 on Ubuntu Linux. Other engines and operating systems are not currently tested, and native Rubydex package availability remains a platform prerequisite.

## Component status

| Component | Responsibility | Status |
|---|---|---|
| Gem packaging and loader | Ruby baseline, executable, public surface | Implemented |
| CLI and project discovery | Commands, root/config resolution, exit codes | Implemented |
| Findings and fingerprints | Evidence-bearing values and stable identity | Implemented |
| Configuration and suppressions | Strict static/runtime validation and post-analysis filtering | Implemented |
| Static adapters and rules | Rubydex/Prism extraction and FA1001–FA1008 | Implemented |
| Reporters | Deterministic text and static JSON schema 1.0 | Implemented |
| Runtime recorder and probes | Bounded JSONL 1.1 sessions and targeted operations | Implemented |
| Scheduler watchdog | Heartbeat stalls and bounded operation overlap | Implemented |
| Operation-liveness monitor | Independent bounded active-operation age evidence | Implemented |
| Synchronization graph | Opt-in bounded ownership/wait/cycle-candidate evidence | Implemented |
| Process-progress monitor | Opt-in inherited-pipe child progress and separate parent session | Implemented |
| Shared operation semantics | Static/runtime semantic profiles and scalar classification | Implemented |
| Combined reporting | Correlated static/runtime finding presentation | Future work |

## Configuration boundary

```yaml
runtime:
  redaction:
    mode: strict
  sampling:
    rate: 0.1
  overhead:
    max_events_per_second: 100
    max_events_per_session: 10000
    max_record_bytes: 16384
    max_session_bytes: 10485760
  watchdog:
    enabled: true
    heartbeat_interval_ms: 25
    stall_threshold_ms: 100
    max_frames: 20
  operation_liveness:
    enabled: true
    poll_interval_ms: 100
    long_active_threshold_ms: 1000
  synchronization_graph:
    enabled: false
    max_identities: 4096
    max_resources: 2048
    max_wait_edges: 2048
    max_cycle_depth: 64
  process_progress:
    enabled: false
    heartbeat_interval_ms: 50
    stall_threshold_ms: 250
    max_processes: 1024
    max_frames_per_poll: 256
    max_buffer_bytes: 65536
  fail_open: true
```

Runtime, watchdog, operation-liveness, synchronization-graph, and process-progress policies are immutable FiberAudit-owned values. CLI activation transports exact-key, size-bounded JSON environment deltas. When process progress is enabled, the supervisor creates one private pipe, explicitly inherits only the writer descriptor, and owns a separate parent-monitor session. Missing activation transport keeps programmatic boot inert. Runtime JSONL schema 1.1 is a separate versioned contract; deterministic static reports remain on schema 1.0.

## Static rules

| ID | Concern | Default severity |
|---|---|---:|
| FA1001 | Subprocess lifecycle and process-wait cooperation | info/medium |
| FA1002 | Thread-wait scheduler coordination | low |
| FA1003 | Synchronization scheduler coordination | low/info |
| FA1004 | True Thread-variable access shared across Fibers | medium |
| FA1005 | `IO.select` scheduler capability requirement | medium |
| FA1006 | Socket allocation and constructor endpoint semantics | low |
| FA1007 | HTTP scheduler cooperation in request-like contexts | medium |
| FA1008 | Explicit blocking-Fiber lexical regions | low/medium |

FA1008 enriches FiberAudit-owned `CallSite` values with an immutable lexical blocking context; Prism/Rubydex nodes do not cross the adapter boundary. The rule emits one finding at each explicit region and raises advisory evidence depth only when shared `OperationSemantics` identifies nested wait-capable calls.

FA1004 uses advisory medium severity because API/context evidence does not prove request-sensitive leakage. It never publishes thread-variable keys or values. FA1006 resolves shared constructor profiles but preserves rule ID and operation strings, so existing fingerprints remain stable.

## Runtime architecture

Runtime instrumentation is activated only by the explicit runtime command:

```text
CLI runtime command
  -> strict Environment settings
  -> conditional RUBYOPT boot
  -> one Lifecycle per process
       -> owner-only Recorder / JSONL 1.1 session
       -> ActiveOperations registry
       -> targeted probe registry
       -> optional Rails integration
       -> scheduler Watchdog
       -> OperationLivenessMonitor
       -> optional SynchronizationGraph
       -> optional process-progress emitter
```

Requiring `fiber_audit` or `fiber_audit/runtime/boot` without the activation marker starts no probes, fibers, threads, or file output. The top-level loader does not require Rails.

### Targeted observations and shared semantics

Narrow idempotent prepend wrappers observe only canonical operations represented by FA1001–FA1008. `OperationSemantics` owns immutable core/optional capability requirements and conditional applicability. Static rules and runtime classification consume the same profiles. Invocation shape is retained only as allowlisted Boolean/nil scalar measurements.

`SchedulerEvidenceClassifier` adds only Boolean/nil measurements:

```text
operation_wait_possible
operation_inventory_only
operation_core_capability_required
operation_core_capability_supported
operation_optional_capability_required
operation_optional_capability_applicable
operation_optional_capability_supported
operation_scheduler_cooperation_available
```

No semantic category Symbol/String or nested classifier value enters JSONL 1.1. A true availability measurement means only that scheduler/Fiber evidence was compatible and, for an optional capability, the captured hook was supported. Required `block` and `kernel_sleep` capabilities are inferred from known scheduler presence rather than measured separately. This does not prove cooperation, progress, safety, or absence of scheduler harm.

Scheduler snapshots preserve actual `Fiber#blocking?` values. Capture failure produces an all-unknown snapshot; readers must preserve nil rather than coerce it to false. Snapshot and classifier fields are additive scalar measurements under the JSONL schema 1.1 envelope; schema 1.0 remains validatable.

### Scheduler watchdog

A scheduler-owned heartbeat reports monotonic progress. The process-local watchdog detects exclusive threshold crossings and emits bounded control events: explicit disabled/absent/active/unsupported state, one stall start/completion pair, safe project-relative frames, and bounded active-operation overlap. Overlap proves only co-occurrence on one Thread. Native work retaining the GVL can prevent both the heartbeat and watchdog Thread from running, so absence of a stall is not certification.

### Operation-liveness monitor

The lifecycle-owned `OperationLivenessMonitor` is independent of watchdog state. It polls an atomic bounded `ActiveOperations::Snapshot` every 100 ms by default and starts evidence when age is strictly greater than the default 1-second threshold. At most ten new threshold crossings emit per poll; both registry and per-poll truncation remain explicit. Operations outside the bounded snapshot may be unobserved, so absence of long-active events is never a complete-coverage claim.

Each observed crossing emits an unsampled-but-budgeted `operation_long_active_started/completed` pair. Registry disappearance closes with `operation_finished: true`; shutdown closes with false. The latter does not claim application failure. Long-active duration is not a scheduler stall, deadlock, or causal diagnosis. Active, disabled, and unsupported state events make monitor coverage explicit.

### Bounds, privacy, and lifecycle

Targeted operations register before ordinary event sampling so watchdog and liveness evidence can observe sampled-out work. Control evidence bypasses random sampling but remains subject to rate, event, record-size, and session-size limits. Drops, truncation, internal errors, unsupported state, and incomplete sessions remain visible.

Runtime values are allowlisted at capture time. Commands and arguments, URLs, addresses, hosts, ports, headers, bodies, payloads, return values, exception messages, environment secrets, and thread-variable keys/values are never retained. Only project-relative locations or explicit unknown/external sentinels are published.

Shutdown follows reverse setup order: probes, Rails integration, synchronization graph, operation liveness, watchdog, process-progress emitter, then recorder. This prevents new registrations while open liveness pairs are closed. Fork rebinding closes only the inherited writer, discards inherited observer references without touching their locks or Threads, resets Fiber context, and constructs a new process-local session and observers.

A successful `exec` may intentionally leave a valid incomplete session without `session_end`. Every reader must validate records with `Runtime::JSONL::Schema` and separately enforce stream ordering/session consistency.

### Verification and performance

`script/scheduler-semantics` behaviorally checks only capabilities consumed by FiberAudit: Process wait variants, coordination hooks, IO.select, localhost address resolution, storage semantics, scheduler replacement, and Ruby 4 IO-close interruption. Every case and the RSpec subprocess are bounded.

`script/scheduler-semantics` and `spec/conformance` exercise blocking/current scheduler state, capability subsets, healthy-heartbeat ownership cycles, and held-versus-released native GVL work on supported CRuby versions. Every scenario is externally bounded. The native extension is built only in a disposable directory; CI requires it while unsupported local toolchains remain an explicit environment limitation.

`benchmark/runtime_probe_overhead.rb` includes absent, installed/inactive, active sampling-zero, active sampling-one, graph-enabled, and parent-monitor scenarios. Results are diagnostic and impose no CI timing threshold.

Remaining runtime work is combined static/runtime correlation and any separately approved coverage contract that could support stronger status semantics.

## Repository map

```text
bin/fiber-audit                                          executable
lib/fiber_audit.rb                                      public loader
lib/fiber_audit/cli.rb                                  command and exit-code boundary
lib/fiber_audit/configuration.rb                        validated configuration
lib/fiber_audit/operation_semantics.rb                  shared operation profiles
lib/fiber_audit/static/                                 static extraction/context/rules
lib/fiber_audit/runtime/                                runtime values, lifecycle, watchdog, probes
lib/fiber_audit/runtime/scheduler_evidence_classifier.rb scalar runtime interpretation
lib/fiber_audit/runtime/operation_liveness_policy.rb    strict monitor policy
lib/fiber_audit/runtime/operation_liveness_monitor.rb   bounded operation-age evidence
script/scheduler-semantics                              used-capability behavior contract
benchmark/runtime_probe_overhead.rb                     local measurement-only benchmark
```

## Maintenance

Update this document when supported architecture changes. Describe features as implemented only after source and meaningful specs exist, record external schema changes as versioned contracts, and keep future work distinct from shipped behavior.
