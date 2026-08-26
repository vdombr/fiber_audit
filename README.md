# FiberAudit

FiberAudit audits Ruby and Rails code for operations that require cooperation from a Fiber scheduler. It provides Rubydex/Prism-backed static hypotheses and explicitly activated observational runtime evidence.

> **Safety boundary:** FiberAudit does not prove fiber safety. runtime observations prove execution, not scheduler harm. Temporal overlap and long-active duration do not prove causality or deadlock. Absence of events does not establish coverage, and FiberAudit never emits an unconditional PASS.

## Requirements and installation

FiberAudit requires Ruby `>= 3.3`. The currently tested environment is CRuby 3.3, 3.4, and 4.0 on Ubuntu Linux. Other engines/platforms are not currently tested, and a compatible native Rubydex package must be available.

```sh
gem install fiber_audit
```

For Bundler:

```ruby
gem "fiber_audit", require: false
```

## Quick start

Run from a project directory or beneath it:

```sh
fiber-audit static
fiber-audit runtime -- bundle exec rspec
```

FiberAudit walks upward to the nearest `Gemfile`, `gems.rb`, or `config/application.rb`. It loads `.fiber-audit.yml` from that root when present. If no project marker is found, it uses the invocation directory and reports the unknown-project fallback.

## Commands

```text
fiber-audit static [--format text|json] [--config PATH] [--out PATH]
                   [--min-severity LEVEL] [--no-color]
fiber-audit runtime [--config PATH] [--out DIRECTORY]
                    [--sampling-rate RATE] [--no-fail-open] -- COMMAND [ARGUMENTS...]
fiber-audit list-rules
fiber-audit explain <RULE_ID>
fiber-audit version
```

Static output defaults to text on a TTY and JSON when piped. `--out PATH` implies JSON, writes relative to the invocation directory, and prints a one-line confirmation. Static exit code `1` means active findings meet the severity threshold; `0` means none do; CLI errors return `2`.

## What FiberAudit reports

Static analysis parses source without executing it and reports hypotheses for FA1001–FA1008. Runtime instrumentation is inert unless activated by `fiber-audit runtime`; each process writes bounded, privacy-conscious JSONL evidence. Static report schema `1.0` is distinct from runtime JSONL schema `1.1`, and retained runtime JSONL `1.0` remains validatable.

Statuses are `FAIL`, `REVIEW`, `PASS_WITH_WARNINGS`, or `NO_FINDINGS`; there is no unconditional `PASS`. Runtime evidence can show execution, temporal overlap, long-active operations, synchronization cycle candidates, or process silence, but none proves scheduler harm, causality, deadlock, coverage, or fiber safety.

## Documentation

- [Installation and project discovery](doc/installation.md)
- [Static command reference](doc/static-command.md)
- [Configuration reference](doc/configuration.md)
- [Suppressions](doc/suppressions.md)
- [Static analysis](doc/static-analysis.md)
- [Rule catalog](doc/rules.md)
- [Static output and report schema](doc/static-output.md)
- [Runtime auditing](doc/runtime.md)
- [Runtime watchdog and liveness](doc/runtime-watchdog-and-liveness.md)
- [Runtime synchronization graph](doc/runtime-synchronization-graph.md)
- [Runtime process progress](doc/runtime-process-progress.md)
- [Maintainer validation](doc/maintainer-validation.md)

See [ARCHITECTURE.md](ARCHITECTURE.md) for implementation boundaries, privacy and lifecycle contracts, and future-work status.
