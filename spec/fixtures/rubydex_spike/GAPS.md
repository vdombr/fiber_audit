# Rubydex 0.2.9 Integration Gaps

This document tracks known limitations and gaps in the Rubydex 0.2.9 integration for FiberAudit's semantic index.

## Current Gaps

### 1. Method Name from Reference

**Gap**: Rubydex::MethodReference only exposes receiver and location, not the method name being called.

**Impact**: Cannot determine which method is being invoked at a call site without additional AST analysis.

**Workaround**: Use Prism-based SourceIndex to extract call sites with method names from the AST.

**Status**: Known limitation in Rubydex 0.2.9 API.

---

### 2. Complete Ancestor Chain with External Dependencies

**Gap**: Rubydex provides `declaration.ancestors` method but may not include all external/framework ancestors without explicit indexing of those dependencies.

**Impact**: Ancestor chain may be incomplete for classes that inherit from or include external libraries not indexed in the workspace.

**Workaround**: The semantic index gracefully handles missing ancestors by returning only the ancestors that Rubydex can resolve. For complete ancestor chains including external dependencies, ensure all required gems are indexed or use runtime reflection as a fallback.

**Status**: Limitation of static analysis scope; Rubydex only analyzes indexed code.

---

### 3. Call Site Extraction with Full Context

**Gap**: Rubydex tracks method references but without method names or full call context (receiver type, argument types, block presence).

**Impact**: Cannot perform precise call-graph analysis or determine fiber-scheduler compatibility at call sites without additional context.

**Workaround**: Combine Rubydex semantic analysis with Prism_DST parsing via SourceIndex to extract:
- Method names at call sites
- Receiver expressions
- Enclosing method context
- Argument information

**Status**: Known limitation in Rubydex 0.2.9; requires hybrid approach.

---

### 4. Dynamic Method Definitions

**Gap**: Rubydex may not fully track methods defined via `define_method`, `method_missing`, or other metaprogramming techniques.

**Impact**: Dynamic methods may not appear in declarations or may lack proper location information.

**Workaround**: Document dynamic methods manually or use runtime introspection for complete method discovery.

**Status**: Inherent limitation of static analysis for dynamic Ruby features.

---

### 5. Constant Aliasing and Indirection

**Gap**: Rubydex tracks constant declarations but may not fully resolve complex aliasing patterns (e.g., `Alias = Original` where Original is later modified).

**Impact**: Constant resolution may not reflect runtime behavior in edge cases.

**Workaround**: Use `resolve_constant` with explicit nesting context for more accurate resolution.

**Status**: Known limitation; constant aliasing semantics are complex in Ruby.

---

## Resolved or Mitigated Issues

### Path Containment

**Previous Gap**: Used string prefix matching for workspace path containment, which could match unrelated directories (e.g., `/workspace` matching `/workspace-other`).

**Resolution**: Implemented Pathname ancestry checking using `path.ascend.include?(root)` for precise workspace boundary detection.

**Status**: ✅ Resolved in WP-1R.

---

### Workspace-First Definition Selection

**Previous Gap**: Selected first definition globally without preference for workspace definitions.

**Resolution**: Implemented `first_workspace_location` helper that filters definitions to workspace-owned ones first, ensuring workspace code takes precedence over external definitions.

**Status**: ✅ Resolved in WP-1R.

---

### Reference Type Conversion

**Previous Gap**: `references_to` returned raw hashes instead of declared Reference Data objects.

**Resolution**: All public methods now return properly typed Data objects (Declaration, Reference, Constant, RubydexGap).

**Status**: ✅ Resolved in WP-1R.

---

### Graceful Degradation

**Previous Gap**: Some methods could raise unhandled exceptions when encountering non-file URIs or malformed locations.

**Resolution**: All public methods now rescue StandardError and return empty arrays or nil as appropriate. Per-reference exception handling ensures one bad reference doesn't break the entire query.

**Status**: ✅ Resolved in WP-1R.

---

## Testing

All gaps are tracked as `RubydexGap` records and can be inspected via `SemanticIndex#gaps` after calling `#build`.

The semantic index is designed to degrade gracefully: if Rubydex cannot provide complete information, the index returns partial results rather than failing.

---

## Version History

- **Rubydex 0.2.9** (WP-1R): Initial integration with comprehensive gap documentation and graceful degradation.
