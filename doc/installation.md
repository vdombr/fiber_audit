# Installation and project discovery

## Requirements

FiberAudit requires Ruby `>= 3.3.0`. The tested support contract is CRuby 3.3, 3.4, and 4.0 on Ubuntu Linux. Rubydex and its native package must be available for the selected Ruby and platform; unsupported native combinations can fail before analysis starts.

## Installing the gem

```sh
gem install fiber_audit
```

## Bundler usage

Add FiberAudit without loading it during application boot:

```ruby
gem "fiber_audit", require: false
```

Then invoke `fiber-audit` from the bundle or through your normal Bundler tooling.

## Project root discovery

When no explicit root is supplied, FiberAudit walks upward from the invocation directory. The nearest directory containing one of these markers is used as the project root:

- `Gemfile`
- `gems.rb`
- `config/application.rb`

Running from a project or a child directory therefore analyzes the same project root. If no marker is found, FiberAudit uses the invocation directory and reports that the project is unknown.

## Configuration file discovery

The default configuration file is `.fiber-audit.yml` at the detected project root. An explicit `--config PATH` is resolved through the project configuration path; relative configuration overrides are relative to the invocation directory. See [the configuration reference](configuration.md) for strict keys and defaults.
