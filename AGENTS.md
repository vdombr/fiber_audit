# AGENTS.md

Repository instructions for LLM coding agents working on FiberAudit.

## Project overview

FiberAudit is a Ruby gem that audits Ruby and Rails applications for operations requiring cooperation from a Fiber scheduler.

It has two established analysis paths:

- `fiber-audit static` performs Rubydex/Prism-backed static analysis.
- `fiber-audit runtime -- COMMAND` records bounded, privacy-conscious observational runtime JSONL.

## Sources of truth

Use these durable sources in this order:

1. Current source code and specs.
2. [`README.md`](README.md) for the user-facing contract.
3. [`ARCHITECTURE.md`](ARCHITECTURE.md) for boundaries and invariants.
4. [`CHANGELOG.md`](CHANGELOG.md) for released behavior.

Do not treat temporary planning or research files as repository instructions or implementation truth unless the user explicitly names one as an input to the current task. Verify every proposed change against current source, specs, and durable documentation before editing.

## Supported environment

- Ruby 3.3, 3.4, and 4.0
- CRuby is the currently tested engine.
- The gem depends on native Rubydex packages.

On unsupported platform combinations, Rubydex may fail to load before specs start. In particular, a local Ruby 4/aarch64 environment may lack a compatible `librubydex_sys.so`. Report this as an environment limitation; do not “fix” application code merely to bypass a missing native extension.

## Repository map

```text
bin/fiber-audit                         executable
lib/fiber_audit.rb                      public loader
lib/fiber_audit/cli.rb                  CLI and exit-code boundary
lib/fiber_audit/audit.rb                static audit coordinator
lib/fiber_audit/configuration.rb        validated configuration
lib/fiber_audit/operation_vocabulary.rb canonical static/runtime operations
lib/fiber_audit/findings/               finding value objects
lib/fiber_audit/correlation/            stable identity and correlation logic
lib/fiber_audit/static/                 static extraction, context, and rules
lib/fiber_audit/runtime/                runtime lifecycle, probes, and JSONL
lib/fiber_audit/reporters/              versioned report contracts
lib/fiber_audit/suppressions/           inline and YAML suppressions
spec/fiber_audit/                       specs mirroring lib/
spec/fixtures/                          deterministic fixtures and goldens
script/scheduler-semantics              executable Ruby scheduler contract checks
```

## Architectural boundaries

Respect these boundaries unless a reviewed plan explicitly changes them:

- Rubydex and Prism objects must not leak beyond their adapters.
- Static rules consume FiberAudit-owned `CallSite` values.
- Rules emit FiberAudit-owned `Finding` values.
- Reporters consume result values; they do not rerun analysis.
- Suppressions are applied after analysis and do not alter rule behavior.
- Runtime instrumentation is activated only by the explicit runtime command.
- Requiring `fiber_audit` must not start threads, fibers, probes, or file output.
- The top-level gem loader must not require Rails.
- Runtime evidence must enrich the common finding model rather than create an unrelated finding system.
- Existing static report schema `1.0` and runtime JSONL schema `1.0` are external contracts.

## Safety and truthfulness invariants

These are product requirements, not optional style preferences:

- FiberAudit does not prove that an application is fiber-safe.
- Never emit or imply unconditional `PASS` without a separately approved runtime-coverage contract.
- Static findings are hypotheses.
- A runtime operation observation proves execution, not scheduler harm.
- Scheduler stall overlap is temporal evidence, not proof of causality.
- Absence of runtime events is not proof that a path was safe or unexecuted.
- Sampling, drops, incomplete sessions, unsupported watchdogs, and internal errors must remain visible.
- Native work retaining Ruby's GVL is a documented watchdog blind spot.
- Unknown ownership or location must remain unknown; do not invent certainty.

## Runtime privacy invariants

Runtime code and reports must not retain or expose:

- commands or command arguments;
- URLs, addresses, hosts, or ports;
- headers, request/response bodies, or payloads;
- exception messages or application return values;
- thread-local keys or values;
- secrets from environment variables;
- absolute paths outside the allowed project-relative representation.

Prefer allowlisted normalized fields over filtering arbitrary raw records after capture. Do not include malformed JSON source text in diagnostics.

## Canonical operations

Static rules and runtime probes share names through `FiberAudit::OperationVocabulary`.

When adding or changing an operation:

1. Update the canonical vocabulary.
2. Update the relevant static rule.
3. Update the relevant runtime probe.
4. Update rule explanation output if necessary.
5. Add positive and negative static fixtures.
6. Add runtime probe coverage.
7. Verify correlation mapping remains complete.

Do not duplicate operation-name tables in unrelated components.

## Working with findings

A published `Finding` must have non-empty evidence. `Collection` and reporter schema validation enforce this invariant.

Stable fingerprints are based on:

```text
rule_id : normalized_path : enclosing_symbol : operation
```

Line number is intentionally excluded. Preserve existing fingerprints when enriching a static finding. Runtime events do not contain enclosing symbols, so they cannot independently recreate a static fingerprint. Correlation must preserve ambiguity instead of claiming false equality.

Severity and confidence are separate:

- severity describes impact if the finding is real;
- confidence describes evidence strength.

Do not raise severity merely because an operation was observed at runtime.

## Runtime JSONL rules

Every runtime process writes a separate owner-only JSONL session. The canonical filename contains launch ID, PID, and session ID, but launch ID and PID are not part of JSONL schema `1.0`.

When implementing readers or correlation:

- validate each record with `Runtime::JSONL::Schema`;
- additionally validate stream ordering and session consistency;
- treat filename provenance as advisory;
- never guess launch or PID from renamed files;
- support incomplete sessions because successful `exec` can intentionally leave a session without `session_end`;
- keep processing independent valid files when tolerant behavior is intended;
- use bounded reads and bounded diagnostics.

## Coding conventions

- Include `# frozen_string_literal: true` in Ruby source and spec files.
- Prefer immutable value objects (`Data.define`) for contracts and results.
- Translate dependency-specific exceptions at adapter boundaries.
- Raise FiberAudit-owned errors from public boundaries.
- Keep deterministic ordering in reports and fixtures.
- Avoid timestamps such as `generated_at` in deterministic reports unless contractually necessary.
- Keep files focused; do not move analysis logic into the CLI or reporters.
- Preserve fail-open runtime behavior where configured.
- Avoid broad tracing, unrestricted monkey patches, `const_missing`, or application autoload side effects.
- Runtime wrappers must be narrow, idempotent, recursion-safe, and inert after deactivation or fork.

## Change workflow for LLM agents

Before editing:

1. Run `git status --short --branch` and identify the exact HEAD.
2. Read the files directly involved in the task.
3. Read relevant specs before designing new APIs.
4. Check `README.md`, `ARCHITECTURE.md`, and `CHANGELOG.md` for public contracts.
5. State any product, schema, compatibility, privacy, or release decision that is not already approved.

While editing:

- Keep one writer in a worktree at a time.
- Prefer small, independently reviewable commits or change sets.
- Add or update tests with behavior changes.
- Do not rewrite unrelated code for style.
- Do not modify generated gem artifacts.
- Do not silently update golden fixtures; explain the intended contract change.
- Do not mark work complete when required tests are failing.

After editing:

1. Inspect the complete diff.
2. Run focused specs for the changed area.
3. Run the full validation suite when the environment supports it.
4. Check docs and changelog for user-visible changes.
5. Report changed files, commands and exit codes, validation limitations, and residual risks.

## Validation commands

Run the narrowest relevant command first, then the full suite:

```sh
bundle exec rspec path/to/changed_spec.rb
bundle exec rspec
bundle exec rubocop
bundle exec ruby script/scheduler-semantics
gem build fiber_audit.gemspec
bundle exec rake release:sanity
```

CI must validate supported Ruby versions 3.3, 3.4, and 4.0.

If Rubydex cannot load locally:

- capture the exact error;
- run independent runtime-only specs through narrow requires when feasible;
- do not claim the full suite passed;
- rely on supported CI for final verification.

## Testing expectations

Use unit, contract, integration, and golden tests as appropriate.

Important existing fixtures include:

- `spec/fixtures/apps/poro_clean`
- `spec/fixtures/apps/rails_blockers`
- `spec/fixtures/apps/rails_contexts`
- `spec/fixtures/reports/rails_blockers_v0.3.0.json`
- `spec/fixtures/runtime/session_v1.jsonl`

For parsers and external contracts, test malformed and adversarial input—not only happy paths. For combined reporting, include multiple processes, fork/exec, incomplete sessions, sampling and drops, watchdog transitions, ambiguous matches, runtime-only observations, privacy sentinels, and deterministic output under shuffled input order.

## Public compatibility checklist

Before changing a public contract, check all of the following:

- CLI syntax and help
- exit codes
- configuration keys and defaults
- rule IDs and operation names
- severity/confidence behavior
- finding fingerprints
- static JSON schema
- runtime JSONL schema
- deterministic text output
- suppression behavior
- privacy guarantees
- supported Ruby versions

Use a new versioned schema for incompatible or structurally distinct output. Do not mutate a strict `1.0` contract in place.

## Documentation expectations

Update documentation when behavior changes:

- `README.md` for user commands and guarantees;
- `ARCHITECTURE.md` for boundaries and implemented status;
- `CHANGELOG.md` for release-visible changes;
- `.fiber-audit.example.yml` for configuration additions.

Describe features as implemented only after source and meaningful specs exist. Keep future work clearly separate from shipped behavior.

## Release boundaries

Do not commit, tag, push, publish a gem, create a release, or modify remote issues/PRs unless the user explicitly authorizes that action.

Built `.gem` files are artifacts, not evidence that the implementation or release is complete.
