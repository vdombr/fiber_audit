# WP-6 Implementation Summary

## Files Created

### 1. lib/fiber_audit/execution_context.rb
- Defines `FiberAudit::Context` module with 11 frozen constants:
  - REQUEST, MIDDLEWARE, CALLBACK, VIEW, JOB, WEBSOCKET, BOOT, CONSOLE, RAKE_TASK, TEST, UNKNOWN
- `ALL` array is frozen and explicitly ordered (not reflection-derived)
- Standalone-requireable with no dependencies

### 2. lib/fiber_audit/static/execution_context_resolver.rb
- API: `new(workspace:)`, `resolve(call_site:)`, `resolve_all(call_sites:)`
- Workspace flexibility: supports both `workspace.ancestors_of` and `workspace.semantic_index.ancestors_of`
- Resolution priority (semantic inheritance outranks path):
  1. **Semantic ancestry** via SEMANTIC_SIGNALS hash:
     - ActionController::Base/API → :request
     - ActiveJob::Base and ActionJob::Base (typo) → :job
     - ActionCable::Channel::Base → :websocket
     - ActionView::Base → :view
  2. **Path-based fallback** using segment-safe checks:
     - config/initializers → :boot
     - lib/tasks or basename Rakefile → :rake_task
     - app/views → :view
     - spec or test segment → :test
     - config.ru with #call method → :middleware
  3. **Callback DSL detection**: method starts with before_/after_/around_ AND semantic ancestry includes ActiveRecord::Base or ActiveSupport::Concern → :callback
  4. **Default**: :unknown
- Enclosing class extraction: handles both `Class#method` and `Class.method` formats
- `resolve_all`: returns new array with immutable CallSite copies (uses Data.define `with` pattern), preserves original order, never mutates inputs
- Never raises: all exceptions caught and return :unknown

### 3. spec/fiber_audit/static/execution_context_resolver_spec.rb
- Uses CallSite-compatible Data.define (TestCallSite) matching WP-2 contract
- MockWorkspace and MockWorkspaceWithSemanticIndex doubles
- Coverage includes:
  - Every context type (request, middleware, callback, view, job, websocket, boot, console, rake_task, test, unknown)
  - Indirect inheritance (Admin::Base < ApplicationController < ActionController::Base)
  - Typo tolerance (ActionJob::Base)
  - PORO → :unknown
  - Adapter errors (workspace raises, malformed call_site)
  - Boundary: my_spec.rb without spec segment → :unknown (not :test)
  - Inheritance outranks path (TestController in spec/ path → :request, not :test)
  - resolve_all immutability and ordering
  - Standalone require
  - Context constants and ALL array frozen/ordered

## Acceptance Commands to Run

```bash
# Run focused specs
bundle exec rspec spec/fiber_audit/static/execution_context_resolver_spec.rb

# Run RuboCop
bundle exec rubocop lib/fiber_audit/execution_context.rb
bundle exec rubocop lib/fiber_audit/static/execution_context_resolver.rb
bundle exec rubocop spec/fiber_audit/static/execution_context_resolver_spec.rb

# Verify standalone require
bundle exec ruby -Ilib -e 'require "fiber_audit/static/execution_context_resolver"; puts FiberAudit::Context::ALL.inspect'

# Commit
git add lib/fiber_audit/execution_context.rb
git add lib/fiber_audit/static/execution_context_resolver.rb
git add spec/fiber_audit/static/execution_context_resolver_spec.rb
git commit -m "WP-6: Add ExecutionContext constants and resolver

- Frozen Context module with 11 explicit constants and ordered ALL array
- ExecutionContextResolver with semantic inheritance priority
- Supports both workspace.ancestors_of and workspace.semantic_index patterns
- Path-based fallback with segment-safe checks
- Conservative callback detection (before_/after_/around_ + model ancestry)
- resolve_all returns immutable copies, never mutates originals
- Never raises; always returns Context symbol
- Comprehensive spec coverage with semantic doubles"
```

## Key Design Decisions

1. **Explicit constants, not reflection**: ALL array is frozen and manually ordered per requirements
2. **Typo tolerance**: ActionJob::Base alongside ActiveJob::Base for :job context
3. **Segment-safe path checks**: splits by '/' and checks for exact segment matches (my_spec.rb ≠ test segment)
4. **Inheritance outranks path**: semantic check happens before path fallback
5. **Immutable resolve_all**: uses Data.define pattern to create copies with execution_context populated
6. **Dual workspace support**: tries ancestors_of directly, then via semantic_index accessor
7. **Never raises**: all public methods rescue StandardError and return :unknown

## No Fixtures Created

The spec uses path strings and mock workspace doubles rather than file fixtures, satisfying "narrowly needed" requirement. All path-based tests use string paths like 'config/initializers/session_store.rb' without requiring actual files.

## Files NOT Modified (per ownership constraints)

- lib/fiber_audit.rb (loader)
- lib/fiber_audit/static/call_site.rb (WP-2)
- lib/fiber_audit/static/call_site_extractor.rb (WP-2)
- spec/fiber_audit/static/call_site_extractor_spec.rb (WP-2)
