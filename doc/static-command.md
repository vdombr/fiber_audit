# Static command reference

## Usage

```text
fiber-audit static [--format text|json] [--config PATH] [--out PATH] [--min-severity LEVEL] [--no-color]
```

Positional arguments are invalid. Use `fiber-audit static --help` for the command's option parser output.

## Options

| Option | Meaning |
|---|---|
| `--format text\|json` | Select text or JSON output explicitly. |
| `--config PATH` | Use a configuration file. |
| `--out PATH` | Write the report to a file. The path is relative to the invocation cwd. |
| `--min-severity LEVEL` | Override the configured minimum severity for this run. |
| `--no-color` | Disable ANSI color in text output. |

## Output selection

Explicit `--format` wins. Without it, `--out` implies JSON; stdout uses text on a TTY and JSON when piped.

## Report file output

`--out PATH` writes only the report to the requested file and prints a one-line confirmation such as `Report written to PATH`. The output path is resolved relative to the invocation directory.

## Minimum severity

Severity is ordered `critical`, `high`, `medium`, `low`, `info`. `--min-severity` is a one-run override of `report.min_severity`; it does not rewrite the configuration file. Suppressed findings are not reportable findings.

## Exit codes

- `0`: no active finding meets the minimum severity.
- `1`: one or more active findings meet the minimum severity.
- `2`: invalid options, configuration, analysis, or report output.

These codes do not prove fiber safety. Static findings are hypotheses, and FiberAudit never emits an unconditional `PASS`.

## Invalid invocations

Unknown options, positional arguments, unsupported formats, missing option values, and invalid configuration return exit code `2` with a diagnostic.
