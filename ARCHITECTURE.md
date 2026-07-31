# FiberAudit Architecture

## 1. Purpose

FiberAudit is a risk-based compatibility auditor for Ruby and Rails applications
running in a fiber-scheduled environment, such as a Rails application served by
Falcon.

It is designed to answer:

1. Which operations may block a scheduler thread?
2. Where do those operations occur?
3. Do they appear in request, middleware, callback, job, WebSocket, boot, or
   other execution contexts?
4. How strong is the evidence for each finding?
5. What should an application owner review or remediate?

FiberAudit does **not** prove that an application is fiber-safe. Static analysis
produces hypotheses; future runtime analysis may confirm scheduler starvation.
A static-only result must never claim an unconditional `PASS`.

> **Repository status:** the current repository implements foundation objects,
> configuration and suppression utilities, and preliminary semantic/syntax
> indexes. The end-to-end v0.1.0 static audit pipeline is planned but not yet
> implemented. In particular, `fiber-audit static`, rules, execution-context
> resolution, reporters, and the audit coordinator are incomplete or absent.

## 2. Scope

### v0.1.0

The v0.1.0 architecture is static-only:

- inspect Ruby source with Rubydex and Prism;
- identify high-signal operations that may block or misuse thread-local state;
- classify findings by execution context where possible;
- attach severity, confidence, evidence, remediation, and a stable fingerprint;
- apply inline and YAML suppressions;
- emit text and versioned JSON reports;
- return CI-friendly exit codes.

### Explicitly outside v0.1.0

The following belong to later releases:

- runtime instrumentation and scheduler watchdogs;
- Rails Railties and middleware;
- Falcon process orchestration;
- static/runtime correlation beyond stable fingerprint generation;
- dependency compatibility intelligence;
- SARIF and HTML reporters;
- runtime-backed `PASS` certification.

## 3. Sources of Truth

When documents disagree, use this precedence:

1. Current code and specs define what is implemented.
2. `fiber_audit_v0.1.0_remediation_plan.md` defines corrected v0.1.0 decisions
   and supersedes older plans where it states a conflict.
3. `fiber_audit_v0.1.0_plan.md` defines the remaining v0.1.0 contracts.
4. `fiber_audit_architecture_plan.md` describes the longer-term product vision.
5. `fiber_audit_v0.1.0_implementation_findings.md` is a review snapshot, not a
   substitute for current code.

The corrected platform target is Ruby `>= 3.2` with CI configured for Ruby 3.2,
3.3, and 3.4. Ruby 3.2 is required because the core model uses `Data.define`.

## 4. Architectural Principles

### 4.1 FiberAudit owns its public contracts

Rubydex and Prism are implementation dependencies. Their objects must not leak
into rules, findings, suppressions, or reporters. Adapters translate external
library data into FiberAudit-owned value objects.

### 4.2 Severity and confidence are separate

- **Severity** represents impact if the finding is real.
- **Confidence** represents the strength of the evidence.

A high-impact heuristic can therefore be `severity: :high` and
`confidence: :low` without conflating the two dimensions.

### 4.3 Findings are the integration boundary

Static rules—and future runtime probes—emit the same `Finding` model.
Suppressions, status derivation, reporters, and future correlation operate on
findings rather than AST or semantic-index objects.

### 4.4 Analysis degrades gracefully

An unresolved constant, unknown execution context, or unsupported Rubydex query
should lower confidence or produce explicit gap metadata. It should not crash an
entire project audit unless analysis cannot continue safely.

### 4.5 Suppression is post-analysis filtering

Rules produce findings independently of suppression policy. The suppression
store partitions findings into active and suppressed sets. Suppressed findings
remain available for reporting and audit history, but do not determine the
active result or exit status.

### 4.6 Static analysis cannot grant `PASS`

The strongest static-only outcomes are `NO_FINDINGS` or
`PASS_WITH_WARNINGS`, accompanied by a static-only disclaimer. A plain `PASS`
requires sufficient runtime coverage and is outside v0.1.0.

## 5. System Context

```text
Ruby/Rails project
  source files
  configuration
  suppressions
        |
        v
+--------------------------+
| FiberAudit static audit  |
|                          |
| Rubydex semantic data    |
| Prism syntax data        |
| Context classification   |
| Static rules             |
| Findings + suppressions  |
+-------------+------------+
              |
              +--> Text report
              +--> JSON report
              +--> Process exit code
```

FiberAudit does not load Rails at the gem entry point. Rails-shaped semantics
are inferred from source structure, inheritance, paths, and callbacks.

## 6. Current Repository Architecture

The implementation is presently a set of disconnected foundations:

```text
require "fiber_audit"
        |
        +-- Findings and value objects
        +-- Fingerprint generation
        +-- Configuration
        +-- Inline/YAML suppression utilities
        +-- Rubydex SemanticIndex       (partial)
        +-- Prism SourceIndex           (placeholder)
        +-- CLI dispatcher              (partial)

fiber-audit static
        |
        +-- prints "Static analysis not yet implemented"
        +-- exits 2
```

### Current component status

| Component | Responsibility | Status |
|---|---|---|
| Gem packaging | Ruby requirement, executable, runtime dependencies | Implemented |
| Main loader | Loads the current public surface | Implemented |
| CLI | Help/version dispatch | Partial; analysis commands are placeholders |
| Findings model | Shared result value objects | Implemented foundation |
| Fingerprint | Stable finding identity | Implemented |
| Configuration | Static globs, rules, formats, severity threshold | Partial validation |
| Suppression parser | Inline and YAML suppression definitions | Partial |
| Suppression store | Partition active and suppressed findings | Implemented foundation |
| `SemanticIndex` | Rubydex adapter | Partial; R1 repairs remain |
| `SourceIndex` | Preliminary Prism call traversal | Placeholder |
| Call-site extractor | FiberAudit-owned `CallSite` values and inference | Planned |
| Context resolver | Rails/request/job/etc. classification | Planned |
| Rule system | Rule base, registry, FA1001–FA1007 | Planned |
| Audit coordinator | End-to-end orchestration and status | Planned |
| Reporters | Text and JSON schema output | Planned |
| Project discovery | Root/config resolution | Planned |
| Runtime engine | Runtime observation and confirmation | Future |

The current loader is `lib/fiber_audit.rb`. The implementation should move a
component from “planned” to “implemented” only when its source and meaningful
spec coverage both exist.

## 7. Planned v0.1.0 Static Pipeline

All components in this diagram after configuration/index construction are
planned unless marked as implemented in the preceding table.

```text
CLI / Project discovery
        |
        v
Configuration + source glob expansion
        |
        +----------------------+
        |                      |
        v                      v
Rubydex SemanticIndex    Prism CallSiteExtractor
(project-wide meaning)   (local syntax and calls)
        |                      |
        +----------+-----------+
                   |
                   v
         ExecutionContextResolver
                   |
                   v
        Enabled rules FA1001–FA1007
                   |
                   v
              Findings
                   |
                   v
       Inline/YAML Suppression Store
                   |
          +--------+---------+
          |                  |
          v                  v
    Active findings    Suppressed findings
          |                  |
          +--------+---------+
                   |
                   v
              Audit::Result
                   |
          +--------+---------+
          |                  |
          v                  v
     Text reporter      JSON reporter
          |                  |
          +--------+---------+
                   |
                   v
              Exit status
```

### Pipeline behavior

1. Detect the project root and configuration file.
2. Validate configuration before analysis starts.
3. Expand included Ruby files and remove excluded paths.
4. Build the Rubydex semantic index once for the workspace.
5. Parse each selected source file once with Prism.
6. Convert call nodes into FiberAudit-owned `CallSite` values.
7. Resolve receivers and execution contexts on a best-effort basis.
8. Run enabled rules over call sites.
9. Publish evidence-bearing findings to a collection.
10. Parse and apply inline and YAML suppressions.
11. Derive the project status from active findings.
12. Render the selected format and return the configured exit status.

## 8. Component Boundaries

### 8.1 CLI and project discovery

**Planned files**

- `lib/fiber_audit/cli.rb`
- `lib/fiber_audit/project.rb`

Responsibilities:

- parse commands and flags;
- discover the project root;
- locate `.fiber-audit.yml` or honor `--config`;
- invoke `Audit`;
- select a reporter;
- map results and errors to process exit codes.

The CLI must not contain AST traversal, rule matching, or report assembly logic.

### 8.2 Configuration

**Current file:** `lib/fiber_audit/configuration.rb`

Recognized static configuration shape:

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
  FA1001:
    enabled: true
    severity: high

report:
  formats:
    - text
    - json
  min_severity: low
```

The configuration boundary owns defaults, type validation, allowed formats,
severity coercion, and rule overrides. Configuration failures must become a
FiberAudit configuration error so the CLI can consistently exit with code 2.

### 8.3 Semantic indexing

**Current file:** `lib/fiber_audit/static/semantic_index.rb`

Rubydex supplies project-wide information:

- declarations;
- constant resolution;
- ancestry and descendants;
- constant references;
- source locations.

`SemanticIndex` is the only component that should directly depend on
`Rubydex::Graph`. It normalizes workspace paths and coordinates and returns
FiberAudit-owned values:

- `Declaration`
- `Reference`
- `Constant`
- `RubydexGap`

Known adapter limitations and required R1 repairs are documented in
`fiber_audit_v0.1.0_remediation_plan.md` and the Rubydex spike fixtures.

### 8.4 Syntax and call-site extraction

**Current placeholder:** `lib/fiber_audit/static/source_index.rb`

**Planned files:**

- `lib/fiber_audit/static/call_site.rb`
- `lib/fiber_audit/static/call_site_extractor.rb`

Prism supplies syntax-level information that Rubydex does not reliably expose,
including method names, receiver source, arguments, lexical nesting, and
precise call-site locations.

The target `CallSite` contract contains:

```text
path, line, column
receiver_source, receiver_constant, method_name
arguments, enclosing_symbol, nesting
execution_context, resolution, confidence
```

The extractor parses each file once and performs conservative receiver
inference. The placeholder `SourceIndex` is not the final public contract and
is expected to be folded into or replaced by `CallSiteExtractor`.

### 8.5 Execution-context resolution

**Planned files:**

- `lib/fiber_audit/execution_context.rb`
- `lib/fiber_audit/static/execution_context_resolver.rb`

Supported contexts are planned as:

```text
request, middleware, callback, view, job, websocket,
boot, console, rake_task, test, unknown
```

Resolution order:

1. semantic inheritance;
2. path-based fallback;
3. callback/DSL syntax hints;
4. `unknown`.

The resolver must never invent certainty. Unknown or heuristic contexts remain
explicit and can lower confidence.

### 8.6 Static rule system

**Planned files:** `lib/fiber_audit/static/rules/`

Rules consume FiberAudit `CallSite` values and emit `Finding` values. They do
not parse files and do not access Rubydex directly.

Planned v0.1.0 rules:

| ID | Concern | Default severity |
|---|---|---:|
| FA1001 | Blocking subprocess operations | high |
| FA1002 | `Thread#join` / `Thread#value` | high |
| FA1003 | Blocking synchronization | medium |
| FA1004 | Thread-local request state | medium/high by operation |
| FA1005 | Explicit `IO.select` | medium |
| FA1006 | Direct socket creation | medium |
| FA1007 | `Net::HTTP` in request-like contexts | high |

A rule registry owns registration, enumeration, configuration enablement, and
metadata used by `list-rules` and `explain`.

### 8.7 Findings and fingerprints

**Current files:**

- `lib/fiber_audit/findings/location.rb`
- `lib/fiber_audit/findings/evidence.rb`
- `lib/fiber_audit/findings/finding.rb`
- `lib/fiber_audit/findings/collection.rb`
- `lib/fiber_audit/findings/severity.rb`
- `lib/fiber_audit/findings/confidence.rb`
- `lib/fiber_audit/correlation/fingerprint.rb`

Severity order:

```text
critical > high > medium > low > info
```

Confidence order:

```text
confirmed > high > medium > low > unknown
```

A finding carries:

```text
rule identity and title
category
severity and confidence
location and enclosing symbol
resolved operation and execution context
message, evidence, and remediation
stable fingerprint
```

The fingerprint is SHA-256 over:

```text
rule_id : normalized_path : enclosing_symbol : operation
```

Line number is intentionally excluded so a finding remains stable when nearby
source lines move.

`Finding.new` currently permits empty evidence while a finding is assembled.
Publication through a collection is intended to require at least one evidence
entry. Constructor and publication paths must enforce the same final invariant.

### 8.8 Suppressions

**Current files:**

- `lib/fiber_audit/suppressions/parser.rb`
- `lib/fiber_audit/suppressions/store.rb`

Inline form:

```ruby
# fiber-audit:disable FA1001 -- executed only by an offline migration
Open3.capture3(command)
# fiber-audit:enable FA1001
```

YAML form:

```yaml
suppressions:
  - rule: FA1001
    symbol: DataMigration#run
    reason: Executed only by an offline task
```

Every suppression requires a reason. Inline directives must come from actual
Ruby comments; directive-looking text in strings, heredocs, or regular
expressions is not a directive. Both disable and enable matching must use
comment locations rather than unrestricted line scans.

### 8.9 Audit coordinator

**Planned file:** `lib/fiber_audit/audit.rb`

The coordinator owns pipeline sequencing, not component internals. Its result
must contain enough information for all reporters:

- active findings;
- suppressed findings;
- parse/analysis errors;
- derived status;
- static-only disclaimer and coverage metadata.

### 8.10 Reporters

**Planned files:** `lib/fiber_audit/reporters/`

Reporters consume `Audit::Result`; they do not rerun analysis or apply
suppressions.

- Text output is optimized for humans and CI logs.
- JSON output is a versioned external contract.
- The planned initial JSON schema version is `1.0`.

`Finding#to_h_for_json` is currently an internal serialization helper. It does
not by itself constitute the complete versioned report schema.

## 9. Dependency Direction

The desired dependency direction is inward toward FiberAudit-owned contracts:

```text
CLI / Reporters
       |
       v
Audit coordinator
       |
       +--> Suppression Store
       +--> Rule Registry
                 |
                 v
              CallSite
                 ^
                 |
      Context Resolver / Extractor
          ^                 ^
          |                 |
     SemanticIndex      Prism syntax
          |
     Rubydex graph

Rules --------------------------> Finding
Suppressions / Reporters -------> Finding
Finding ------------------------> Fingerprint, Location, Evidence
```

Forbidden dependencies:

- rules must not depend on Rubydex or Prism node classes;
- reporters must not depend on indexes or rules;
- suppressions must not mutate rule behavior;
- the top-level gem loader must not require Rails;
- v0.1.0 code must not depend on runtime instrumentation modules.

## 10. Status and Exit Contracts

### Planned project statuses

| Status | Meaning |
|---|---|
| `FAIL` | At least one active critical or high finding |
| `REVIEW` | Medium risk, or unresolved low/unknown-confidence risk requiring review |
| `PASS_WITH_WARNINGS` | Only low or informational findings |
| `NO_FINDINGS` | No active findings |

Every v0.1.0 report must include:

> This is a static-only audit. PASS cannot be granted without runtime coverage.

### Planned exit codes

| Code | Meaning |
|---:|---|
| 0 | No active finding at or above the configured threshold |
| 1 | At least one active finding at or above the threshold |
| 2 | Configuration or analysis error |
| 3 | Reserved; not emitted in v0.1.0 |

These result and exit-code semantics are planned; the current `static` command
always reports that analysis is not implemented and exits 2.

## 11. Error Handling

Errors should be split into two classes of behavior:

- **Recoverable analysis gaps:** record an error/gap, lower confidence, and
  continue with other files or references.
- **Invalid invocation or configuration:** raise a FiberAudit-owned error and
  let the CLI return exit code 2.

External exceptions should be translated at their adapter boundary. Downstream
components should not need to rescue Rubydex-, Prism-, or YAML-specific errors.

Shared error-class placement remains an R1 design decision; the remediation
plan recommends a dedicated `lib/fiber_audit/errors.rb`.

## 12. Testing Architecture

Tests mirror `lib/` under `spec/`.

### Current coverage

- finding value objects and ordering;
- fingerprint stability and path normalization;
- collection filtering and evidence publication through `add`;
- configuration defaults and partial validation;
- inline/YAML suppression parsing and matching;
- preliminary Rubydex adapter behavior.

### Required v0.1.0 coverage

- exact `CallSite` extraction and receiver inference;
- execution-context classification;
- positive and negative fixtures for every rule;
- shadowed-constant negatives to avoid name-only false positives;
- stable fingerprints across repeated analysis;
- suppression behavior, including comment-only enable/disable directives;
- project-root and configuration discovery;
- text and JSON reporter contracts;
- golden JSON output;
- clean, findings, and invalid-config CLI exit paths.

Fixture applications should remain small and deterministic:

```text
spec/fixtures/apps/poro_clean
spec/fixtures/apps/rails_blockers
spec/fixtures/apps/rails_contexts
spec/fixtures/reports/rails_blockers_v0.1.json
```

CI is configured to run linting, specs, and gem packaging on Ruby 3.2, 3.3,
and 3.4. The workflow configuration does not itself prove that remote CI has
passed.

## 13. Runtime Architecture Beyond v0.1.0

The long-term architecture adds a runtime branch alongside static analysis:

```text
Static engine                   Runtime session
Rubydex + Prism                 Instrumentation + watchdog
      |                                  |
      v                                  v
Static findings                   Runtime events
      |                                  |
      +---------------+------------------+
                      |
                      v
             Fingerprint correlation
                      |
                      v
       Confirmed / static-only / runtime-only findings
```

Planned runtime concepts include:

- observational JSONL sessions;
- scheduler-stall detection;
- targeted `Module#prepend` instrumentation;
- limited `TracePoint` use;
- Rails request and callback correlation;
- static/runtime evidence merging;
- runtime coverage sufficient to support future `PASS` semantics.

Runtime components must continue to emit or enrich the common finding model
rather than establish a parallel reporting model.

## 14. Repository Map

```text
lib/fiber_audit.rb                         current public loader
lib/fiber_audit/cli.rb                     partial CLI
lib/fiber_audit/configuration.rb           partial configuration boundary
lib/fiber_audit/findings/                  current value objects
lib/fiber_audit/correlation/fingerprint.rb current stable identity
lib/fiber_audit/suppressions/              current suppression utilities
lib/fiber_audit/static/semantic_index.rb   partial Rubydex adapter
lib/fiber_audit/static/source_index.rb     placeholder Prism index

fiber_audit_v0.1.0_remediation_plan.md     corrected implementation sequence
fiber_audit_v0.1.0_plan.md                 v0.1.0 contracts
fiber_audit_architecture_plan.md           long-term product architecture
```

## 15. Maintaining This Document

Update this document when an implementation wave lands:

1. Move a component from planned to implemented only when source and meaningful
   specs exist.
2. Update diagrams when dependency direction changes.
3. Record external report-schema changes as versioned contract changes.
4. Keep future runtime architecture separate from current static behavior.
5. Prefer links to detailed remediation tasks over embedding transient bug
   lists here.
6. Never use the existence of a built gem artifact as evidence that a release or
   architecture stage is complete.
