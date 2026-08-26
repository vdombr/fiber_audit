# Examples

These examples show common FiberAudit workflows from a project directory. They are schematic: replace paths with project-relative locations that make sense for your repository, and avoid putting application data into reports or shared notes.

FiberAudit reports static hypotheses and explicitly collected runtime evidence. It does not prove that an application is fiber-safe, and it never emits an unconditional `PASS`.

## Static scan from a project

Run a static audit from the project root, or from a directory beneath it:

```sh
fiber-audit static
```

FiberAudit discovers the nearest project root and reads `.fiber-audit.yml` from that root when the file exists. Static findings are hypotheses about operations that may need scheduler cooperation; they are not proof that a path is unsafe or safe.

For complete command syntax and exit-code behavior, see the [static command reference](../doc/static-command.md).

## Save a JSON report

To print JSON to standard output, choose the JSON format explicitly:

```sh
fiber-audit static --format json
```

To write a deterministic JSON report to a file, use `--out`:

```sh
fiber-audit static --out tmp/fiber-audit-static.json
```

`--out` implies JSON and writes relative to the invocation directory. The static report schema and status values are documented in [static output and report schema](../doc/static-output.md).

## Raise or lower the reporting threshold for one run

Use `--min-severity` when you want a one-run threshold override without changing configuration:

```sh
fiber-audit static --min-severity high
```

The threshold controls which active findings are reportable for that run. It does not prove that findings below the threshold are safe, and it does not change suppression behavior. See the [static command reference](../doc/static-command.md) for severity ordering and exit codes.

## Use project configuration

FiberAudit automatically loads `.fiber-audit.yml` from the detected project root when present. To use a specific configuration file for one invocation, pass `--config`:

```sh
fiber-audit static --config .fiber-audit.yml
```

Configuration is strict. Include and exclude arrays replace defaults rather than merging with them, rule overrides are explicit, and invalid configuration returns a command error. See the [configuration reference](../doc/configuration.md) for supported keys.

## Suppress an accepted static hypothesis

Use suppressions only for reviewed static hypotheses that your team accepts or handles elsewhere. For example, an inline suppression requires a non-empty reason in source:

```ruby
system(command) # fiber-audit:disable FA1001 -- reviewed maintenance boundary
```

Suppressions are applied after analysis. They hide matching findings from the active report, but they do not prove fiber safety, runtime coverage, or absence of scheduler risk. See [suppressions](../doc/suppressions.md) for inline and YAML syntax.

## Collect runtime evidence for one command

Runtime instrumentation is activated only through the runtime command and the required `-- COMMAND` separator:

```sh
fiber-audit runtime -- bundle exec rspec
```

To write runtime JSONL sessions to a chosen directory, pass `--out` before the separator:

```sh
fiber-audit runtime --out tmp/fiber-audit-runtime -- bundle exec rspec
```

Requiring `fiber_audit` does not start runtime probes, threads, fibers, or file output. Runtime sessions are bounded and privacy-conscious; commands and arguments are not retained as evidence. See [runtime auditing](../doc/runtime.md) for activation, session lifecycle, failure behavior, and JSONL semantics.

## Read results without over-claiming

Interpret FiberAudit output as evidence with explicit limits:

- Static findings are hypotheses, not proof that an application is unsafe or safe.
- Runtime observations prove that an operation executed under instrumentation; they do not prove scheduler harm.
- Scheduler-stall overlap, long-active operations, synchronization cycle candidates, and process silence are temporal or structural evidence, not causality or deadlock proof.
- Missing findings, missing events, sampled-out events, dropped records, unsupported observers, internal errors, and incomplete sessions do not prove safety or coverage.
- FiberAudit statuses do not include an unconditional `PASS`.

Keep reports and examples privacy-safe. Do not paste real URLs, addresses, hosts, ports, headers, bodies, payloads, secrets, exception messages, return values, thread-local data, or external absolute paths into shared documentation.

## Related references

- [Static command reference](../doc/static-command.md)
- [Static output and report schema](../doc/static-output.md)
- [Configuration reference](../doc/configuration.md)
- [Suppressions](../doc/suppressions.md)
- [Runtime auditing](../doc/runtime.md)
