# Changelog

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
