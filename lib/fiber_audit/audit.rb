# frozen_string_literal: true

require 'pathname'
require_relative 'errors'
require_relative 'findings/severity'
require_relative 'findings/confidence'
require_relative 'findings/location'
require_relative 'findings/evidence'
require_relative 'findings/finding'
require_relative 'findings/collection'
require_relative 'suppressions/parser'
require_relative 'suppressions/store'
require_relative 'execution_context'
require_relative 'static/semantic_index'
require_relative 'static/call_site'
require_relative 'static/call_site_extractor'
require_relative 'static/execution_context_resolver'
require_relative 'static/rules/built_ins'

module FiberAudit
  # Wave R4 WP-7: Audit coordinator.
  #
  # Orchestrates the complete static analysis workflow:
  #   1. Expand/clean root
  #   2. Resolve target files (include/exclude globs, Ruby only, sorted, deduped)
  #   3. Build SemanticIndex(root:)
  #   4. Extract call sites with absolute paths (unchanged)
  #   5. Copy call sites and parse errors to root-relative paths (portable)
  #   6. Resolve execution contexts on root-relative call sites
  #   7. Parse inline suppressions with root-relative paths
  #   8. Parse YAML suppressions (relative to root unless absolute)
  #   9. Run enabled rules via Collection publication
  #  10. Apply suppressions and min_severity filter
  #  11. Determine status and build immutable Result
  #
  class Audit
    Coverage = Data.define(:analysed_files, :total_call_sites, :rules_run)
    Result = Data.define(:findings, :suppressed, :parse_errors, :coverage, :status)

    # Status constants
    STATUS_FAIL                 = 'FAIL'
    STATUS_REVIEW               = 'REVIEW'
    STATUS_PASS_WITH_WARNINGS   = 'PASS_WITH_WARNINGS'
    STATUS_NO_FINDINGS          = 'NO_FINDINGS'

    def initialize(configuration:, root:)
      @configuration = configuration
      expanded_root = Pathname.new(root).expand_path.cleanpath
      raise ArgumentError, "audit root is not a directory: #{expanded_root}" unless expanded_root.directory?

      @root = expanded_root.realpath
      freeze
    end

    attr_reader :root

    def call
      pipeline = run_pipeline
      active, suppressed = pipeline.fetch(:store).apply(pipeline.fetch(:findings))
      filtered_active = filter_by_severity(active)
      filtered_suppressed = filter_by_severity(suppressed)

      build_result(pipeline, filtered_active, filtered_suppressed)
    end

    private

    # ── File resolution ──────────────────────────────────────────────

    # Resolve files using include/exclude globs.
    # Returns sorted, deduplicated array of absolute paths to regular .rb files.
    def resolve_files
      included = expand_include_globs
      excluded = expand_exclude_globs

      excluded_lookup = excluded.to_h { |file| [file, true] }

      included
        .reject { |file| excluded_lookup.key?(File.expand_path(file)) }
        .select { |file| inside_root?(file) }
        .map { |file| File.expand_path(file) }
        .uniq
        .sort
    end

    def expand_include_globs
      @configuration.static_include.flat_map do |pattern|
        Dir.glob(File.join(@root.to_s, pattern))
           .select { |f| File.file?(f) && f.end_with?('.rb') }
      end
    end

    def expand_exclude_globs
      @configuration.static_exclude.flat_map do |pattern|
        Dir.glob(File.join(@root.to_s, pattern)).map { |file| File.expand_path(file) }
      end
    end

    def inside_root?(path)
      expanded = File.expand_path(path)
      expanded == @root.to_s || expanded.start_with?("#{@root}#{File::SEPARATOR}")
    end

    def run_pipeline
      files = resolve_files
      semantic_index = build_semantic_index
      extraction = extract_call_sites(files, semantic_index)
      call_sites = relativize_call_sites(extraction.call_sites)
      context_resolver = build_context_resolver(semantic_index)
      enabled_rules = build_enabled_rules(semantic_index, context_resolver)

      {
        files: files,
        extraction: extraction,
        parse_errors: relativize_parse_errors(extraction.parse_errors),
        store: build_suppression_store(files),
        enabled_rules: enabled_rules,
        findings: run_rules(enabled_rules, context_resolver.resolve_all(call_sites: call_sites))
      }
    end

    def build_result(pipeline, active, suppressed)
      coverage = Coverage.new(
        analysed_files: pipeline.fetch(:files).size,
        total_call_sites: pipeline.fetch(:extraction).call_sites.size,
        rules_run: pipeline.fetch(:enabled_rules).size
      )

      Result.new(
        findings: active.dup.freeze,
        suppressed: suppressed.dup.freeze,
        parse_errors: pipeline.fetch(:parse_errors).dup.freeze,
        coverage: coverage,
        status: determine_status(active)
      )
    end

    # ── Semantic index ───────────────────────────────────────────────

    def build_semantic_index
      Static::SemanticIndex.new(root: @root.to_s).build
    end

    # ── Call site extraction ─────────────────────────────────────────

    # CallSiteExtractor receives absolute file paths exactly unchanged.
    def extract_call_sites(files, semantic_index)
      Static::CallSiteExtractor.new(
        files: files,
        semantic_index: semantic_index
      ).call
    end

    # ── Path relativization ──────────────────────────────────────────

    # Copy call sites to immutable root-relative paths (inside-root only).
    def relativize_call_sites(call_sites)
      call_sites.map do |cs|
        rel_path = to_root_relative(cs.path)
        cs.class.new(
          path: rel_path,
          line: cs.line,
          column: cs.column,
          receiver_source: cs.receiver_source,
          receiver_constant: cs.receiver_constant,
          method_name: cs.method_name,
          arguments: cs.arguments,
          enclosing_symbol: cs.enclosing_symbol,
          nesting: cs.nesting,
          execution_context: cs.execution_context,
          resolution: cs.resolution,
          confidence: cs.confidence,
          fiber_context: cs.fiber_context
        )
      end
    end

    # Copy parse errors to immutable root-relative paths (inside-root only).
    def relativize_parse_errors(parse_errors)
      parse_errors.map do |pe|
        rel_path = to_root_relative(pe.path)
        Static::CallSiteExtractor::ParseError.new(
          path: rel_path,
          message: pe.message,
          line: pe.line
        )
      end
    end

    # Convert absolute path to root-relative, inside-root only.
    def to_root_relative(absolute_path)
      return absolute_path unless absolute_path

      root_str = @root.to_s
      if absolute_path == root_str || absolute_path.start_with?("#{root_str}/")
        Pathname.new(absolute_path).relative_path_from(@root).to_s
      else
        absolute_path
      end
    end

    # ── Context resolution ───────────────────────────────────────────

    def build_context_resolver(semantic_index)
      Static::ExecutionContextResolver.new(workspace: semantic_index)
    end

    # ── Suppressions ─────────────────────────────────────────────────

    def build_suppression_store(files)
      Suppressions::Store.new(
        inline_suppressions: parse_inline_suppressions(files),
        yaml_suppressions: parse_yaml_suppressions
      )
    end

    # Parse inline suppressions with root-relative path while reading absolute file.
    def parse_inline_suppressions(files)
      files.flat_map do |absolute_path|
        content = File.read(absolute_path)
        relative_path = to_root_relative(absolute_path)
        Suppressions::Parser.parse_inline(relative_path, content)
      end
    end

    # YAML suppressions path relative to root unless absolute.
    def parse_yaml_suppressions
      suppressions_path = @configuration.suppressions_path
      return [] unless suppressions_path

      yaml_path = if Pathname.new(suppressions_path).absolute?
                    suppressions_path
                  else
                    File.join(@root.to_s, suppressions_path)
                  end

      Suppressions::Parser.parse_yaml(yaml_path)
    end

    # ── Rules ────────────────────────────────────────────────────────

    def build_enabled_rules(semantic_index, context_resolver)
      registry = Static::Rules::BuiltIns.registry(
        workspace: semantic_index,
        context_resolver: context_resolver
      )
      registry.enabled_for(@configuration)
    end

    # Run all enabled rules; collect findings via Collection publication.
    def run_rules(enabled_rules, call_sites)
      findings = enabled_rules.flat_map { |rule| rule.analyze(call_sites: call_sites) }
      Collection.new(findings).to_a
    end

    # ── Severity filtering ───────────────────────────────────────────

    def filter_by_severity(findings)
      min_index = Severity.index(@configuration.min_severity)
      findings.select { |f| Severity.index(f.severity) <= min_index }
    end

    # ── Status determination ─────────────────────────────────────────

    # FAIL:                any critical or high severity
    # REVIEW:              any medium, or low with unknown confidence
    # PASS_WITH_WARNINGS:  nonempty low/info remainder
    # NO_FINDINGS:         empty findings
    # Never PASS.
    def determine_status(findings)
      return STATUS_NO_FINDINGS if findings.empty?

      severities = findings.map(&:severity)

      return STATUS_FAIL if severities.any? { |s| %i[critical high].include?(s) }
      return STATUS_REVIEW if severities.include?(:medium)
      return STATUS_REVIEW if findings.any? { |finding| review_confidence?(finding) }

      has_low_or_info = findings.any? { |finding| %i[low info].include?(finding.severity) }
      return STATUS_PASS_WITH_WARNINGS if has_low_or_info

      STATUS_NO_FINDINGS
    end

    def review_confidence?(finding)
      finding.severity != :info && %i[low unknown].include?(finding.confidence)
    end
  end
end
