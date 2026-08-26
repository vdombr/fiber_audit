# Maintainer validation

## Documentation drift checks

Keep command syntax, option names, configuration keys, rule IDs, event kinds, and schema fields aligned with the implementation. Check that every README link resolves and that detailed reference content remains in `doc/` rather than being duplicated in the landing page.

## Command and help checks

Run the static and runtime help paths and compare them with [the command references](static-command.md) and [runtime auditing](runtime.md). Verify invalid invocations return CLI error code `2`, while static reportable findings use code `1`.

## Schema and safety language checks

Static report schema `1.0` and runtime JSONL schema/versioning are separate contracts. Static findings remain hypotheses. Runtime observations prove execution rather than scheduler harm. Absence of runtime events is not proof of safety or coverage. Do not add unconditional `PASS` language.

## Runtime privacy and lifecycle checks

Review capture-time allowlists, project-relative locations, bounded records, drops, unsupported states, internal errors, and incomplete sessions. Confirm requiring the gem remains inert and that observer teardown, fork refresh, and successful `exec` behavior are documented accurately.

## Package contents and release sanity

Every regular `doc/**/*` file is part of the gem's documentation surface. `bundle exec rake release:sanity` builds the gem, checks its packaged file list, and prints the packaged files. Remove generated gem artifacts after local checks when they are not needed.

## Environment limitations

The tested contract is CRuby 3.3, 3.4, and 4.0 on Ubuntu Linux with a compatible Rubydex native package. A local unsupported Ruby/platform combination may fail before specs load; report that limitation rather than bypassing application code. Documentation validation does not prove application fiber safety.
