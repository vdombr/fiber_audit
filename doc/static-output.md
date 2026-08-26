# Static output and report schema

## Format selection and file output

Use `--format text` or `--format json` for an explicit format. Without it, `--out PATH` implies JSON; stdout selects text on a TTY and JSON when piped. `--out` writes the report file and prints a one-line confirmation.

## Exit codes and statuses

- `0` means no active finding is at or above the configured minimum severity.
- `1` means one or more active findings meet that threshold; suppressed findings do not count.
- `2` means invalid options, configuration, analysis, or report output.
- `3` is reserved and is not emitted.

Statuses are exactly:

- `FAIL` — critical or high findings;
- `REVIEW` — medium or other review-worthy findings;
- `PASS_WITH_WARNINGS` — only low or informational findings;
- `NO_FINDINGS` — no findings at the configured threshold.

FiberAudit never emits an unconditional `PASS`.

## Safety boundary

The static report is static-only. Static findings are hypotheses: the report does not prove fiber safety, runtime coverage, scheduler-harm causality, or absence of risk. No finding or event should be interpreted as proof merely because it is present or absent.

## JSON schema 1.0

The deterministic static JSON report has schema version `1.0` and these top-level keys:

```text
schema_version, tool_version, status, disclaimer, summary, coverage,
findings, suppressed, parse_errors
```

`summary` contains non-negative integer counts for `critical`, `high`, `medium`, `low`, `info`, `suppressed`, and `total`. `coverage` contains `analysed_files`, `total_call_sites`, and `rules_run`.

Each `findings` and `suppressed` entry contains `rule_id`, `title`, `category`, `severity`, `confidence`, `location`, `symbol`, `operation`, `execution_context`, `message`, `evidence`, `remediation`, and `fingerprint`. Optional fields are JSON-safe or null. `location` is null or contains `path`, `line`, and `column`; paths are project-relative where known.

Each `evidence` entry contains non-empty `source` and `message` plus JSON-safe `details`. `parse_errors` entries contain `path`, `message`, and `line`; parse errors are non-fatal report data for skipped files while analysis continues on other files.

Findings and report collections are deterministically ordered at the static report boundary. Runtime JSONL is a separate contract from static report schema `1.0`; see [runtime auditing](runtime.md) for that contract.
