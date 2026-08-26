# Runtime auditing

## Activation boundary

Runtime instrumentation is explicit. Requiring `fiber_audit`, or loading the boot path without the activation marker, remains inert: it starts no probes, threads, fibers, or file output. `fiber-audit runtime` builds settings, enables targeted probes, and supervises the supplied child.

## Command syntax and options

```text
fiber-audit runtime [--config PATH] [--out DIRECTORY] [--sampling-rate RATE] [--no-fail-open] -- COMMAND [ARGUMENTS...]
```

The `--` separator is required, as is a nonempty child command. The default output directory is `tmp/fiber-audit-runtime` beneath the project root. `--out DIRECTORY` selects another directory relative to the invocation directory. `--sampling-rate RATE` overrides sampling for the run. `--no-fail-open` makes runtime recording failures fail the Ruby child instead of being suppressed.

## Child activation environment

The supervisor supplies field-category settings rather than application data: an activation marker (`FIBER_AUDIT_RUNTIME_BOOT`), serialized runtime settings and failure mode, a `RUBYOPT` boot require, `RUBYLIB`, optional watchdog/liveness/synchronization/process-progress payloads or descriptors, and `FIBER_AUDIT_RUNTIME_PROBES`. Commands and arguments are not retained as evidence.

## Boot failure behavior

Boot and recorder failures are fail-open by default so instrumentation does not change application behavior. `--no-fail-open` is the fail-closed override. Activation failures are suppressed only in fail-open mode.

## Session lifecycle and JSONL files

Each process writes a separate owner-only JSONL session. A session creates UUID/timestamp, output path, session, writer, and recorder state; observers are installed only when recording is active. Shutdown stops observers and probes in reverse ownership order, then closes the recorder and records errors as applicable. A successful `exec` can intentionally leave an incomplete session without `session_end`.

## Targeted probes and late requires

The targeted families are `FiberContext`, `Subprocess`, `ThreadWait`, `Synchronization`, `ThreadState`, `IOSelect`, `Socket`, and `HTTP`. Libraries may load after boot; late `require` handling rescans only known targets. It is narrow, idempotent, explicit-runtime-only, refreshes fork state, and records instrumentation failures rather than enabling broad tracing.

## Privacy and bounds baseline

Capture-time allowlisting and bounded retention exclude commands, command arguments, URLs, addresses, hosts, ports, headers, request/response bodies, payloads, exception messages, application return values, thread-local keys or values, environment secrets, and absolute paths outside the allowed project-relative representation. Sampling, drops, truncation, unsupported observers, internal errors, and incomplete sessions remain visible.

## Runtime JSONL schema versions

Runtime JSONL supports versions `1.0` and `1.1`; the current writer version is `1.1`. Record types are `session_start`, `event`, and `session_end`. Every envelope contains `schema_version`, `record_type`, `session_id`, `sequence`, `recorded_at`, `monotonic_ns`, and `payload`.

| Version | `session_start` payload |
|---|---|
| `1.0` | `tool_version`, `ruby_version`, `policy` |
| `1.1` | The `1.0` fields plus `process_role` |

Runtime JSONL is separate from static report schema `1.0`; retained `1.0` sessions remain validatable.

## What this page does not prove

Runtime observations prove execution, not scheduler harm. Missing, sampled-out, dropped, unsupported, or errored events, and incomplete sessions, are not coverage or safety proof; they are not safety proof for the application. Scheduler stalls, long-active operations, synchronization cycles, and process-progress silence are separate evidence topics; this page does not interpret them.

## Related runtime evidence

- [Watchdog and liveness](runtime-watchdog-and-liveness.md)
- [Synchronization graph](runtime-synchronization-graph.md)
- [Process progress](runtime-process-progress.md)
