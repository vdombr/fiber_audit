# WP-4 Implementation Summary

## Files Created

### 1. lib/fiber_audit/static/rules/base.rb
- Implements the Base rule class with metadata DSL
- Class methods: `id`, `severity`/`default_severity`, `confidence`/`default_confidence`, `description`
- Validates severity and confidence using `FiberAudit::Severity.coerce` and `FiberAudit::Confidence.coerce`
- Constructor: `initialize(workspace:, context_resolver:, configuration:)`
- Protected readers: `workspace`, `context_resolver`, `configuration`
- `analyze(call_sites:)` raises `NotImplementedError`
- Frozen `CONTEXT_CEILING` table with exact mappings:
  - request/middleware/websocket → :critical
  - callback/view/job → :high
  - boot → :medium
  - console/test → :info
  - rake_task → :low
  - unknown → nil
- Private `severity_for(default_sev, context)` method:
  1. Applies `configuration.severity_override(self.class.id)` first
  2. Applies monotonic context ceiling (only raises, never lowers)
  3. Treats nil/unrecognized context as :unknown
- Private `severity_index(severity)` helper

### 2. lib/fiber_audit/static/rules/registry.rb
- Implements Registry class with Enumerable
- Constructor: `new(workspace: nil, context_resolver: nil)`
- `register(rule_class)` returns self for chaining
  - Validates: must be Base subclass, must have id, no duplicate ids
  - Raises ArgumentError on validation failure
- `[](id)` and `find(id)` - find by string or symbol ID
- `list` - returns insertion-ordered duplicate-safe array (returns copy)
- `each` - for Enumerable support
- `enabled_for(configuration)` - returns instantiated Base objects
  - Filters by `configuration.rule_enabled?(rule_id)`
  - Initializes each with workspace, context_resolver, and configuration
  - Never mutates class defaults
- Standalone requires (only needs base.rb)

### 3. spec/fiber_audit/static/rules/base_spec.rb
Comprehensive spec coverage:
- Test subclass with id, severity, confidence, description
- Metadata DSL tests (id, severity/default_severity, confidence/default_confidence, description)
- Coercion validation (invalid severity/confidence raise ArgumentError)
- Constructor stores dependencies
- Protected readers accessible to subclasses
- `analyze` raises NotImplementedError on base, works in subclass
- CONTEXT_CEILING table exhaustive tests
- `severity_for` monotonic behavior:
  - All context ceiling combinations (request→critical, callback→high, etc.)
  - Unknown/nil context leaves severity unchanged
  - Unrecognized context treated as unknown
  - Configuration override applied before context
  - Override replaces default entirely
  - Context ceiling still applies on top of override
  - Never lowers even with override
- `severity_index` helper returns correct indices
- Exhaustive monotonic table spec (5 severities × 11 contexts = 55 combinations)
- Monotonic invariant verification

### 4. spec/fiber_audit/static/rules/registry_spec.rb
Comprehensive spec coverage:
- Test rule subclasses (A, B, C with different IDs)
- Constructor with optional workspace and context_resolver
- `register` returns self, allows chaining
- Validation: rejects non-Base, missing id, duplicate id
- `[]` finds by string and symbol ID, returns nil for unknown
- `find` alias for `[]`
- `list` maintains insertion order, returns duplicate-safe copy
- Enumerable: each, map, select, any?, count
- `enabled_for` filters by rule_enabled?
  - All enabled returns all instances
  - Partial enabled filters correctly
  - All disabled returns empty array
  - Instances initialized with correct dependencies
  - Returns Base instances not classes
- Class defaults immutability (not mutated by overrides)
- Integration scenario (register → find → enumerate → instantiate)

## Implementation Details

### Key Design Decisions

1. **Metadata DSL**: Both `severity` and `default_severity` work as setter/getter methods. `severity(:high)` sets with coercion, `severity` or `default_severity` gets.

2. **Context Ceiling Application**: The monotonic rule is implemented as:
   - Get base severity (override || default)
   - Get ceiling for context (nil for unknown)
   - If `Severity.index(base) > Severity.index(ceiling)`, raise to ceiling
   - Otherwise keep base (never lower)

3. **Registry Dependency Injection**: The registry holds workspace and context_resolver, then passes them along with configuration when instantiating rules in `enabled_for`.

4. **Standalone Requires**: Both files only require their direct dependencies (base.rb requires severity and confidence; registry.rb requires base).

5. **Validation**: Registry validates that registered classes are Base subclasses with non-empty IDs, preventing registration errors early.

## Acceptance Commands (to be run manually)

```bash
# Run WP-4 specs
bundle exec rspec spec/fiber_audit/static/rules/base_spec.rb
bundle exec rspec spec/fiber_audit/static/rules/registry_spec.rb

# Run with documentation format
bundle exec rspec spec/fiber_audit/static/rules/base_spec.rb spec/fiber_audit/static/rules/registry_spec.rb --format documentation

# Run RuboCop on the new files
bundle exec rubocop lib/fiber_audit/static/rules/base.rb
bundle exec rubocop lib/fiber_audit/static/rules/registry.rb
bundle exec rubocop spec/fiber_audit/static/rules/base_spec.rb
bundle exec rubocop spec/fiber_audit/static/rules/registry_spec.rb

# Verify the implementation loads
bundle exec ruby -Ilib -e '
  require "fiber_audit/static/rules/base"
  require "fiber_audit/static/rules/registry"
  
  class TestRule < FiberAudit::Static::Rules::Base
    id "FA9999"
    severity :high
    confidence :high
    description "Test"
    
    def analyze(call_sites:)
      []
    end
  end
  
  registry = FiberAudit::Static::Rules::Registry.new
  registry.register(TestRule)
  puts "OK: #{registry["FA9999"].id}"
'
```

## Contract Compliance

✓ Frozen Base contract:
  - metadata DSL with id, severity/default_severity, confidence/default_confidence, description
  - validate/coerce using FiberAudit Severity/Confidence
  - initialize(workspace:, context_resolver:, configuration:) with protected readers
  - analyze(call_sites:) raises NotImplementedError
  - Frozen CONTEXT_CEILING table with exact mappings
  - Monotonic rule: severity less severe than ceiling becomes exactly ceiling
  - Never lower a more severe default
  - Apply configuration.severity_override before context
  - Nil/unrecognized context treated as unknown
  - severity_index helper provided

✓ Frozen Registry contract:
  - new(workspace: nil, context_resolver: nil)
  - Enumerable
  - register returns self
  - [] and find by string/symbol ID
  - list returns insertion-ordered duplicate-safe array
  - enabled_for filters by rule_enabled? and returns initialized Base instances
  - Never mutates class defaults
  - Rejects non-Base, missing ID, duplicate ID
  - Standalone requires

✓ File ownership:
  - Only edited: lib/fiber_audit/static/rules/base.rb
  - Only edited: lib/fiber_audit/static/rules/registry.rb
  - Only edited: spec/fiber_audit/static/rules/base_spec.rb
  - Only edited: spec/fiber_audit/static/rules/registry_spec.rb
  - Did NOT edit loader or shared files

## Notes

- Bash commands were blocked by the permission system, so specs could not be run automatically
- The implementation follows the frozen contracts exactly as specified
- All validation uses ArgumentError (not ConfigurationError) per the task requirements
- The monotonic invariant is thoroughly tested with exhaustive table specs
- Test subclasses are defined inline in specs (no separate fixture files needed)
