# FiberAudit

FiberAudit audits Ruby and Rails code for operations that can block the thread
running a Fiber scheduler. Version 0.1.0 performs static analysis only.

> **Static-only disclaimer:** This is a static-only audit. PASS cannot be
> granted without runtime coverage.

## Requirements and installation

FiberAudit supports maintained Ruby versions starting with Ruby 3.3.

```sh
gem install fiber_audit
```

Or add it to a bundle and run `bundle install`:

```ruby
gem "fiber_audit", require: false
```

## Quick start

Run from a project directory or any directory beneath it:

```sh
fiber-audit static
```

FiberAudit walks upward to find the nearest `Gemfile`, `gems.rb`, or
`config/application.rb`. It loads `.fiber-audit.yml` from that root when the
file exists.

```text
fiber-audit static [--format text|json] [--config PATH] [--out PATH]
                   [--min-severity LEVEL] [--no-color]
fiber-audit list-rules
fiber-audit explain FA1001
fiber-audit version
```

Output defaults to text on a TTY and JSON when piped. `--out PATH` defaults to
JSON, writes only the report to that file, and prints a one-line confirmation.
Explicit `--format` always wins.

## Shipped rules

| ID | Detects | Default severity |
|---|---|---|
| FA1001 | Blocking subprocess operations | high |
| FA1002 | `Thread#join` and `Thread#value` | high |
| FA1003 | Thread-oriented synchronization | medium |
| FA1004 | Thread-local state access | high/medium |
| FA1005 | Explicit `IO.select`/`Kernel.select` | medium |
| FA1006 | Direct socket construction | medium |
| FA1007 | Synchronous HTTP in request-like contexts | high |

Use `fiber-audit explain <RULE_ID>` for exact targets and remediation.

## Configuration

Copy `.fiber-audit.example.yml` to `.fiber-audit.yml` in the project root.
Paths and globs are rooted at the detected project. An explicit `--config`
path is resolved from the directory where the command was invoked.

```yaml
static:
  include:
    - app/**/*.rb
    - lib/**/*.rb
    - config/**/*.rb
  exclude:
    - vendor/**/*
    - tmp/**/*
    - db/schema.rb
  suppressions_path: .fiber-audit-suppressions.yml

rules:
  FA1007:
    enabled: false
  FA1003:
    severity: low

report:
  formats: [text, json]
  min_severity: low
```

`--min-severity` overrides `report.min_severity` for one run. Severity ordering
is `critical`, `high`, `medium`, `low`, `info`; findings below the threshold
are omitted and do not affect the exit code. The default `low` threshold keeps
informational findings silent.

## Suppressions

Every suppression requires a non-empty reason. Directive-looking text inside
strings, heredocs, or regular expressions is ignored.

Suppress one line:

```ruby
system(command) # fiber-audit:disable FA1001 -- trusted maintenance command
```

Suppress a block:

```ruby
# fiber-audit:disable FA1003 -- protected legacy boundary
mutex.synchronize { update_record }
# fiber-audit:enable FA1003
```

A separate YAML file can suppress by rule and optionally by symbol or
operation. Point `static.suppressions_path` at the file:

```yaml
suppressions:
  - rule: FA1001
    symbol: Reports::Generator#call
    operation: Open3.capture3
    reason: isolated worker process with an external timeout
```

Missing reasons and invalid configuration return exit code 2.

## Static statuses

- `FAIL` — at least one critical or high finding.
- `REVIEW` — a medium finding, or a non-informational low/unknown-confidence
  finding.
- `PASS_WITH_WARNINGS` — only low or informational findings.
- `NO_FINDINGS` — no findings at the configured threshold.

FiberAudit never emits unconditional `PASS` in v0.1.0.

## Exit codes

| Code | Meaning |
|---|---|
| 0 | No active finding at or above the configured threshold |
| 1 | One or more active findings at or above the threshold |
| 2 | Invalid options, configuration, analysis, or report output |
| 3 | Reserved; never emitted by v0.1.0 |

Source parse errors are included in report data while analysis continues on
other files.

See [ARCHITECTURE.md](ARCHITECTURE.md) for implementation boundaries and the
future runtime-analysis architecture.
