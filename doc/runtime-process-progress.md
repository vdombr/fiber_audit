# Process progress evidence

## What it observes

Process-progress monitoring records bounded scalar heartbeat and progress observations for tracked processes. It is evidence of observed process activity or silence, not a scheduler-harm, causality, deadlock, coverage, or fiber-safety conclusion.

## Activation and sessions

Monitoring is opt-in through `runtime.process_progress` and is activated only by `fiber-audit runtime -- COMMAND`. Requiring `fiber_audit` does not start monitoring. When enabled, the parent monitor writes a separate runtime JSONL `1.1` session with `process_role: parent_monitor`; it never appends to a child session. This runtime contract is distinct from the static JSON report schema `1.0`.

## Transport

An inherited pipe is internal activation plumbing. The process-progress policy is serialized through runtime settings, and a writer descriptor is included only when the transport exists. Child writes are nonblocking and may drop under pipe pressure rather than delaying application work.

## Event kinds and measurements

Events include:

- `process_progress_monitor_active`
- `process_progress_process_observed`
- `process_progress_stall_started`
- `process_progress_stall_completed`
- `process_progress_monitor_truncated`
- `process_progress_monitor_unsupported`
- `process_progress_monitor_completed`

Heartbeat frames expose only scalar `process_pid`, `process_generation`, `progress_sequence`, and `child_monotonic_ns`. Parent-observed silence may create a stall start; a later frame may create a stall completion.

## Bounds and interpretation

Policies expose `heartbeat_interval_ns`, `stall_threshold_ns`, `max_processes`, `max_frames_per_poll`, and `max_buffer_bytes`. Diagnostics keep stale frame counts, sequence gaps, malformed frames, decoder truncations, process-limit drops, and monitor internal errors visible. Active, unsupported, and completed states are retained, including degraded completion. Silence is temporal evidence only, not a causality claim or complete coverage.

## Example JSONL

The following is schematic and contains no child command data:

```json
{"record_type":"event","payload":{"kind":"process_progress_process_observed","measurements":{"process_pid":42,"process_generation":1,"progress_sequence":7,"child_monotonic_ns":123000}}}
{"record_type":"event","payload":{"kind":"process_progress_stall_started","measurements":{"process_pid":42,"stall_threshold_ns":250000000}}}
{"record_type":"event","payload":{"kind":"process_progress_stall_completed","measurements":{"process_pid":42,"progress_sequence":8}}}
```

## Privacy

Parent evidence is scalar and allowlisted. It does not retain child commands or arguments, URLs, hosts, ports, headers, bodies, payloads, exception messages, environment secrets, or application return values. It also does not retain arbitrary process data.

## Out of scope and non-goals

This page does not document scheduler watchdog/liveness or synchronization graph semantics; see their dedicated pages. Process-progress silence does not prove scheduler harm, causality, deadlock, safety, or that an unobserved path was covered. Runtime JSONL `1.1` remains separate from static schema `1.0`, and there is no unconditional `PASS` based on process progress.
