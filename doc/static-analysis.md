# Static analysis

## What static analysis can and cannot say

Static analysis parses source and does not execute application code. Static findings are hypotheses about operations that may require cooperation from a Fiber scheduler; they do not prove fiber safety, scheduler harm, causality, or runtime coverage.

## Pipeline

### 1. Resolve target files

FiberAudit discovers the project root, applies configured include and exclude globs, keeps Ruby source inside that root, and sorts paths deterministically.

### 2. Build the semantic index

Rubydex builds the semantic index behind a FiberAudit adapter. Dependency objects remain inside that adapter.

### 3. Parse source and extract call sites

Prism parses each Ruby file. The extractor emits FiberAudit-owned call sites with conservative receiver, location, symbol, and execution-context data. It does not execute source.

### 4. Normalize paths and resolve execution context

Locations become project-relative. Rails-aware contexts such as request, middleware, job, websocket, boot, test, and task are resolved without turning context into proof of impact.

### 5. Run enabled rules

Enabled rules consume owned call sites and emit owned, evidence-bearing findings. See the [rule catalog](rules.md). Canonical operation names and scheduler capabilities are shared with runtime classification.

### 6. Apply suppressions and severity filtering

Suppressions are applied after analysis, then the configured minimum-severity threshold selects reportable findings. Suppression and filtering do not alter rule behavior.

## Parse errors

A parse error is retained as non-fatal report data for the skipped file while analysis continues for other files. Invalid configuration or report output is a CLI error.

## Determinism and portability

Target paths, findings, and report ordering are deterministic for the same inputs. Rubydex native availability is platform-dependent; a missing compatible native extension can prevent startup rather than produce a finding.

## Related documentation

- [Static command](static-command.md) and [configuration](configuration.md)
- [Rule catalog](rules.md)
- [Static output and schema](static-output.md)
- [Runtime auditing](runtime.md)
