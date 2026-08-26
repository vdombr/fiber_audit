# Suppressions

## Inline suppressions

Inline directives are recognized from Prism comments:

```ruby
system(command) # fiber-audit:disable FA1001 -- trusted maintenance boundary
```

A non-empty reason after `--` is required. Directive-looking text in strings, heredocs, or regular expressions is ignored.

## Block suppressions

A block can be disabled and re-enabled around source:

```ruby
# fiber-audit:disable FA1003 -- protected legacy boundary
mutex.synchronize { update_record }
# fiber-audit:enable FA1003
```

Trailing suppressions and line/range directives follow the same required-reason rule.

## YAML suppressions

Set `static.suppressions_path`, or use the conventional suppression file, with a `suppressions:` array:

```yaml
suppressions:
  - rule: FA1001
    symbol: Reports::Generator#call
    operation: Open3.capture3
    reason: isolated worker process with an external timeout
```

Each entry requires `rule` and a non-empty `reason`. `symbol` and `operation` are optional filters.

## Matching behavior

YAML suppressions are evaluated first. They can match rule and, when supplied, symbol or canonical operation. Inline suppressions match root-relative path, line or range, and rule. Matching does not change rule behavior; suppressions are applied after analysis.

## Required reasons

Reasons must be non-empty and explain the local boundary or accepted exception. A missing or blank reason is invalid rather than an implicit approval.

## Limits and safety

Suppressions hide matching findings from the active report; they do not prove fiber safety or runtime coverage. Static findings remain hypotheses. Paths are project-relative, and suppression parsing does not retain commands, arguments, payloads, secrets, or arbitrary application values.
