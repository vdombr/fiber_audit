# Configuration reference

## File location and resolution

FiberAudit discovers `.fiber-audit.yml` at the detected project root. `--config PATH` selects an explicit file; a relative override is resolved from the invocation directory. Configuration is strict and is loaded for both static and runtime commands.

## Strict validation

The only top-level keys are `static`, `rules`, `report`, and `runtime`. Unknown keys, invalid types, and values outside policy bounds are configuration errors.

`static` accepts `include`, `exclude`, and `suppressions_path`. `report` accepts `formats` (`text` and/or `json`) and `min_severity`. Each rule entry accepts only `enabled` and `severity`. Runtime validation accepts the policy groups and keys implemented by the runtime command, including `redaction.mode`, `sampling.rate`, `overhead`, `watchdog`, `operation_liveness`, `synchronization_graph`, `process_progress`, and `fail_open`.

## Static file selection

When omitted, static includes are:

- `app/**/*.rb`
- `lib/**/*.rb`
- `config/**/*.rb`
- `config/initializers/**/*.rb`

Default excludes are:

- `vendor/**/*`
- `tmp/**/*`
- `node_modules/**/*`
- `db/schema.rb`

Configured include and exclude arrays replace the defaults; they are not merged with them. Paths are interpreted beneath the project root.

## Rule configuration

A rule can be disabled or given a severity override:

```yaml
rules:
  FA1007:
    enabled: false
  FA1003:
    severity: low
```

## Report configuration

Severity ordering from most to least severe is `critical`, `high`, `medium`, `low`, `info`. `report.min_severity` controls which active findings are reportable. A static command's `--min-severity LEVEL` overrides that value for one run only.

## Runtime configuration keys

Runtime keys are documented here for strict-validation completeness. Runtime activation, sessions, probes, watchdog, synchronization graph, and process-progress evidence are described in the [runtime reference](runtime.md) and its related pages.

```yaml
runtime:
  redaction: { mode: strict }
  sampling: { rate: 0.1 }
  overhead:
    max_events_per_second: 100
    max_events_per_session: 10000
    max_record_bytes: 16384
    max_session_bytes: 10485760
  watchdog: { enabled: true, heartbeat_interval_ms: 25, stall_threshold_ms: 100, max_frames: 20 }
  operation_liveness: { enabled: true, poll_interval_ms: 100, long_active_threshold_ms: 1000 }
  synchronization_graph: { enabled: false, max_identities: 4096, max_resources: 2048, max_wait_edges: 2048, max_cycle_depth: 64 }
  process_progress: { enabled: false, heartbeat_interval_ms: 50, stall_threshold_ms: 250, max_processes: 1024, max_frames_per_poll: 256, max_buffer_bytes: 65536 }
  fail_open: true
```

## Complete example

```yaml
static:
  include: [app/**/*.rb, lib/**/*.rb, config/**/*.rb, config/initializers/**/*.rb]
  exclude: [vendor/**/*, tmp/**/*, node_modules/**/*, db/schema.rb]
  suppressions_path: .fiber-audit-suppressions.yml
rules:
  FA1007: { enabled: false }
report:
  formats: [text, json]
  min_severity: low
```
