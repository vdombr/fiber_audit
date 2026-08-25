# FiberAudit

FiberAudit audits Ruby and Rails code for operations that require cooperation
from a Fiber scheduler. It provides Rubydex/Prism-backed static hypotheses and
an explicitly activated observational runtime recorder.

> **Safety disclaimer:** FiberAudit does not prove that an application is
> fiber-safe. Runtime observations prove execution, not scheduler harm; temporal
> overlap and long-active duration do not prove causality or deadlock. Absence of
> events does not establish execution coverage. FiberAudit never emits an
> unconditional `PASS`.

## Requirements and installation

The gem requires Ruby 3.3 or newer. CI tests CRuby 3.3, 3.4, and 4.0 on Ubuntu
Linux. Other Ruby engines and operating systems are not currently part of the
tested support contract. Native Rubydex packages must be available for the
selected platform.

```sh
gem install fiber_audit
```

Or add it to a bundle:

```ruby
gem "fiber_audit", require: false
```

## Quick start

Run from a project directory or beneath it:

```sh
fiber-audit static
fiber-audit runtime -- bundle exec rspec
```

FiberAudit walks upward to the nearest `Gemfile`, `gems.rb`, or
`config/application.rb` and loads `.fiber-audit.yml` from that root when present.

```text
fiber-audit static [--format text|json] [--config PATH] [--out PATH]
                   [--min-severity LEVEL] [--no-color]
fiber-audit runtime [--config PATH] [--out DIRECTORY]
                    [--sampling-rate RATE] [--no-fail-open] -- COMMAND [ARGUMENTS...]
fiber-audit list-rules
fiber-audit explain FA1001
fiber-audit version
```

Static output defaults to text on a TTY and JSON when piped. `--out PATH`
defaults to JSON, writes only the report to that file, and prints a one-line
confirmation. Explicit `--format` always wins.

## Shipped rules

| ID | Detects | Default severity |
|---|---|---|
| FA1001 | Subprocess creation, replacement, waiting, and streams | info/medium |
| FA1002 | Thread-wait scheduler coordination | low |
| FA1003 | Synchronization scheduler coordination | low/info |
| FA1004 | Thread-variable access shared across Fibers on one Thread | medium |
| FA1005 | `IO.select` scheduler capability requirement | medium |
| FA1006 | Socket allocation and constructor endpoint semantics | low |
| FA1007 | HTTP scheduler cooperation in request-like contexts | medium |
| FA1008 | Explicit `Fiber.new(blocking: true)` and `Fiber.blocking` regions | low/medium |

FA1008 reports the explicit blocking-Fiber region at low severity. When a
canonical wait-capable operation is lexically nested in that region, it reports
medium severity and includes the nested operation as static evidence. This is a
source-level hypothesis; it does not prove that the region executed or caused a
stall.

FA1004 reports true `thread_variable_get/set` access. It does not retain keys or
values and does not claim that request-sensitive leakage occurred. FA1006 keeps
stable `<Class>.new` operation identities while distinguishing inventory-only
allocation, address resolution/network endpoint setup, local connection, and
unknown IPSocket-subclass construction.

Use `fiber-audit explain <RULE_ID>` for exact targets and remediation.

## Runtime audit

The runtime command observes only the command supplied after `--`; static
analysis never executes discovered source fragments. Each observed Ruby process
writes a separate owner-only JSONL schema `1.1` session under
`tmp/fiber-audit-runtime` by default. FiberAudit still validates retained schema
`1.0` sessions; it does not reinterpret them as `1.1`. Runtime JSONL schema
`1.1` is independent of the deterministic static report schema `1.0`, which
remains unchanged. A successful `exec` can intentionally leave a valid session
without `session_end`.

Targeted probes cover the operations represented by FA1001–FA1008. Events retain
canonical operation names, monotonic duration, conservative project-relative
callsites, execution context, ephemeral Thread/Fiber identities, and allowlisted
scalar measurements. They never retain commands, command arguments, URLs,
addresses, hosts, ports, headers, payloads, responses, return values, exception
messages, environment secrets, or thread-variable keys and values.

Libraries such as Open3, Monitor, Socket, Net::HTTP, and OpenURI may load after
runtime boot; FiberAudit rescans only known targets after `require`. Runtime
wrappers remain inert outside explicit activation and after deactivation or fork.

### Scheduler snapshots and operation classification

A targeted operation snapshots scheduler state at its start. Measurement failure
is represented as `nil` (unknown), never coerced to false:

```text
scheduler_present: true | false | nil
fiber_blocking: true | false | nil
scheduler_io_select_supported: true | false | nil
scheduler_process_wait_supported: true | false | nil
scheduler_address_resolve_supported: true | false | nil
```

Operation-specific evidence adds Boolean/nil measurements for core and optional
capabilities:

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

`operation_scheduler_cooperation_available: true` means the captured scheduler
and Fiber mode were compatible and every applicable required hook was present.
Required core coordination hooks such as `block` and `kernel_sleep` are inferred
from known scheduler presence rather than measured separately. This does not
prove that the operation cooperated, progressed, or was safe. `nil` remains
unknown or not applicable. Invocation applicability is derived without retaining
values: `IO.select` records only timeout presence and known-zero status, while
socket and HTTP probes record only endpoint-name-resolution applicability.

### Scheduler watchdog

The watchdog records one bounded start/completion pair when a scheduler-owned
heartbeat stops progressing past its threshold. Scheduler-friendly waits should
continue heartbeats. State events are:

- `watchdog_active` — a heartbeat ran under an installed scheduler;
- `watchdog_absent` — no scheduler was observed;
- `watchdog_unsupported` — the scheduler could not safely host observation;
- `watchdog_disabled` — watchdog policy disabled observation.

Bounded `scheduler_stall_operation_overlap` events associate active operation
sequences with a stall on the same Thread. They establish temporal overlap, not
causality. Native work retaining Ruby's GVL can prevent the watchdog Thread from
running until the work returns.

### Long-active operation monitor

The independent operation-liveness monitor polls the bounded active-operation
registry. By default it polls every 100 ms and emits after an observed operation
remains active for strictly more than 1 second. All targeted operation types are
eligible, but entries beyond the snapshot bound can remain unobserved under
registry pressure; truncation is explicit and absence is not a coverage claim:

- `operation_liveness_active`;
- `operation_liveness_disabled`;
- `operation_liveness_unsupported`;
- `operation_long_active_started`;
- `operation_long_active_completed`.

Ordinary registry removal closes a pair with `operation_finished: true`.
Shutdown closes an open pair with `operation_finished: false`; that value does
not mean the application operation failed. Long-active evidence means only that
a targeted operation remained registered across the threshold. It is not a
scheduler stall, proven deadlock, or proof of scheduler harm.

Watchdog, liveness-state, overlap, and long-active events bypass random sampling
but still consume recorder rate, event, record-size, and session-size budgets.
Snapshot and per-poll truncation, drops, unsupported states, internal errors, and
incomplete sessions remain visible. A successful `exec` may intentionally leave
a session without `session_end`.

### Explicit blocking-Fiber provenance

Runtime wrappers distinguish `Fiber.new(blocking: true)` from `Fiber.blocking` and
publish only presence, bounded nesting depth, nearest context kind, and
truncation. Provenance starts when the application block executes, is reset on
fork/shutdown, and is separate from the scheduler snapshot. It establishes the
source of explicit blocking mode, not scheduler harm.

### Synchronization ownership/wait graph

`runtime.synchronization_graph.enabled` opts into bounded phase evidence for
Mutex, Monitor, MonitorMixin, and ConditionVariable operations. The graph uses
session-local monotonic actor/resource IDs rather than raw object IDs, tracks
only transitions observed by narrow wrappers, and makes identity/resource/wait
and cycle-search truncation visible. `sync_cycle_candidate` means the bounded
observed ownership/wait graph contained a cycle; it is not an unconditional
application-deadlock or causality verdict.

### Parent process-progress monitor

`runtime.process_progress.enabled` opts into a private inherited pipe carrying
fixed-size scalar heartbeat frames. Child writes are nonblocking and drop under
pipe pressure rather than delaying application work. The supervisor writes a
separate owner-only JSONL `1.1` session with `process_role: parent_monitor`; it
never appends to child sessions. Stall start/completion records mean only that a
tracked `(pid, generation)` stopped/resumed progress past the configured
threshold. Process silence is temporal evidence, not proof of scheduler harm or
causality. Native work retaining Ruby's GVL is observable by this parent monitor;
work releasing the GVL should permit the child progress Thread to continue.
Sampling, drops, malformed-frame counts, sequence gaps, process limits,
incomplete sessions, unsupported state, and internal errors remain visible.

Rails execution contexts (`request`, `middleware`, `job`, and `websocket`) are
captured when Rails integration is active. Bounded immutable Fiber storage
propagates logical context to child Fibers without retaining request data.
Combined static/runtime reporting remains future work.

## Configuration

Copy `.fiber-audit.example.yml` to `.fiber-audit.yml`. Paths and globs are rooted
at the detected project; explicit `--config` is resolved from the invocation
directory.

```yaml
static:
  include: [app/**/*.rb, lib/**/*.rb, config/**/*.rb]
  exclude: [vendor/**/*, tmp/**/*, db/schema.rb]
  suppressions_path: .fiber-audit-suppressions.yml

rules:
  FA1007:
    enabled: false
  FA1003:
    severity: low

report:
  formats: [text, json]
  min_severity: low

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

Configuration is strict: unknown sections or keys, invalid types, and values
outside policy bounds return exit code 2. `--min-severity` overrides
`report.min_severity` for one static run. Severity ordering is `critical`,
`high`, `medium`, `low`, `info`; the default `low` threshold omits informational
findings.

## Suppressions

Every suppression requires a non-empty reason. Directive-looking text inside
strings, heredocs, or regular expressions is ignored.

```ruby
system(command) # fiber-audit:disable FA1001 -- trusted maintenance command
```

```ruby
# fiber-audit:disable FA1003 -- protected legacy boundary
mutex.synchronize { update_record }
# fiber-audit:enable FA1003
```

YAML suppressions can match rule and optionally symbol or operation:

```yaml
suppressions:
  - rule: FA1001
    symbol: Reports::Generator#call
    operation: Open3.capture3
    reason: isolated worker process with an external timeout
```

## Static statuses and exit codes

- `FAIL` — at least one critical or high finding.
- `REVIEW` — a medium finding, or non-informational low/unknown-confidence risk.
- `PASS_WITH_WARNINGS` — only low or informational findings.
- `NO_FINDINGS` — no findings at the configured threshold.

FiberAudit never emits unconditional `PASS`.

| Code | Meaning |
|---|---|
| 0 | No active finding at or above the configured threshold |
| 1 | One or more active findings at or above the threshold |
| 2 | Invalid options, configuration, analysis, or report output |
| 3 | Reserved; not emitted |

Source parse errors remain report data while analysis continues on other files.

## Development and semantic verification

```sh
bundle exec rspec
bundle exec rubocop
bundle exec ruby script/scheduler-semantics
FIBER_AUDIT_BENCH_ITERATIONS=2000 bundle exec ruby benchmark/runtime_probe_overhead.rb
gem build fiber_audit.gemspec
bundle exec rake release:sanity
```

The semantic script and `spec/conformance` use bounded local Threads, Fibers,
pipes, localhost operations, child processes, and a disposable native extension.
CI runs them on CRuby 3.3, 3.4, and 4.0. The native fixture contrasts work that
retains the GVL with `rb_thread_call_without_gvl`; unavailable local toolchains
produce an explicit bounded skip, while CI requires the fixture.

The benchmark reports absent, installed/inactive, active sampling-zero, active
sampling-one, synchronization-graph, and process-progress-monitor workloads.
It is diagnostic only: there is no host-dependent CI timing threshold.

See [ARCHITECTURE.md](ARCHITECTURE.md) for implementation boundaries and the
runtime truthfulness, privacy, lifecycle, and schema contracts.
