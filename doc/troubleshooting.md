# Troubleshooting and FAQ

Use this page by symptom. It summarizes what FiberAudit has already reported and points to the detailed references for command syntax, schemas, rule meaning, runtime sessions, and suppressions.

## Static run exits with `1`

Exit code `1` means the static audit completed and found one or more active findings at or above the configured reporting threshold. It is not a crash.

Treat those findings as static hypotheses about operations that may require scheduler cooperation. They do not prove that the application is unsafe, and a quiet or low-severity run is not an unconditional `PASS`. See the [static command reference](static-command.md) for exit codes and [static output and report schema](static-output.md) for statuses and finding fields.

## Static run exits with `2`

Exit code `2` means FiberAudit could not complete the requested static invocation. Common causes include invalid options, invalid configuration, analysis setup failures, or report-writing failures. This is distinct from exit code `1`, which is a completed audit with reportable findings.

Check the diagnostic, then compare the invocation with the [static command reference](static-command.md) and configuration with the [configuration reference](configuration.md).

## Report contains `parse_errors`

`parse_errors` are report data for files that could not be parsed. They are non-fatal: FiberAudit skips the affected file and continues analysis for other files.

A report containing `parse_errors` is not the same thing as an invalid invocation failure. Keep the skipped-file uncertainty visible when interpreting the report, because missing findings in skipped files are not proof of safety.

## Configuration is rejected

Configuration validation is strict. The only top-level keys are `static`, `rules`, `report`, and `runtime`. Unknown keys, invalid types, and values outside policy bounds are configuration errors.

When `.fiber-audit.yml` is absent at the discovered project root, FiberAudit uses defaults. When an explicit `--config` path is supplied and that file is missing or invalid, the command fails instead of silently falling back.

Configured `static.include` and `static.exclude` arrays replace the defaults; they are not merged with default patterns. See the [configuration reference](configuration.md) for accepted keys and examples.

## Runtime separator or command is missing

Runtime auditing requires a `--` separator and a nonempty child command:

```sh
fiber-audit runtime -- COMMAND
```

Options before `--` belong to FiberAudit. Tokens after `--` belong to the wrapped command and are not retained as runtime evidence. See [runtime auditing](runtime.md) for the option parsing boundary and activation behavior.

## Wrapped command ran but no runtime session appeared

Runtime probes are activated only by `fiber-audit runtime`; requiring `fiber_audit` or adding the gem to an application does not start probes, threads, fibers, or file output.

If the wrapped command ran but no session file appeared:

1. Confirm the command used `fiber-audit runtime -- COMMAND`.
2. Check the output directory. The default is `tmp/fiber-audit-runtime` under the project root; `--out DIRECTORY` is resolved from the invocation directory.
3. Check runtime configuration such as `runtime.fail_open` and output bounds.
4. Retry with `--no-fail-open` when you need instrumentation setup failures to fail visibly instead of being suppressed.
5. Treat incomplete sessions carefully. A successful `exec` can intentionally leave a valid session without `session_end`.

Missing events, sampled-out events, dropped records, unsupported observers, internal errors, or an absent session are not proof that a path was covered or fiber-safe.

## Runtime returned a nonzero status

`fiber-audit runtime` preserves the wrapped child command's exit status or signal mapping when supervision succeeds. A nonzero result can therefore come from the child command itself.

FiberAudit CLI or setup failures return `2`. Use that distinction before treating the failure as an audit problem. Runtime observations still prove execution only; they do not prove scheduler harm, causality, deadlock, coverage, or fiber safety.

## Rule meaning is unclear

Start with the finding fields: `rule_id`, `severity`, `confidence`, `location`, `symbol`, `operation`, `execution_context`, `evidence`, `remediation`, and `fingerprint` explain why a static hypothesis was emitted.

Use the installed rule commands for the exact version you are running:

```sh
fiber-audit list-rules
fiber-audit explain <RULE_ID>
```

The [rule catalog](rules.md) gives a concise overview without replacing `fiber-audit explain <RULE_ID>`.

## Suppression did not match

Check whether the suppression is inline or YAML, whether it includes a non-empty reason, and whether its rule, path or line range, symbol, and operation match the finding. YAML suppressions can filter by rule, symbol, and canonical operation; inline suppressions match project-relative path, line or range, and rule.

Suppressions are applied after analysis. They hide matching findings from the active report, but they do not change rule behavior and do not prove fiber safety or runtime coverage. See [suppressions](suppressions.md) for syntax and matching details.

## FiberAudit or Rubydex fails before analysis starts

Failures before analysis begins are environment or toolchain failures, not completed audits. FiberAudit requires Ruby `>= 3.3`, and the tested support contract is CRuby 3.3, 3.4, and 4.0 on Ubuntu Linux. A compatible native Rubydex package must be available for the selected Ruby and platform.

If Rubydex or another native package cannot load, verify installation requirements and the selected Ruby/platform combination. See [installation and project discovery](installation.md). Do not interpret a pre-analysis load failure as a static result.

## Safety and privacy reminders

Keep uncertainty explicit when sharing or interpreting results:

- Static findings are hypotheses.
- Runtime observations prove execution, not scheduler harm.
- Scheduler stall overlap is temporal evidence, not proof of causality.
- Absence of findings, events, stalls, or sessions is not proof of safety or coverage.
- Suppressed findings do not prove fiber safety.

When asking for help, prefer minimized, schematic excerpts. Do not paste real commands or command arguments, URLs, addresses, hosts, ports, headers, request or response bodies, payloads, secrets, exception messages, application return values, thread-local keys or values, or external absolute paths.
