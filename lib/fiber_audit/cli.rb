# frozen_string_literal: true

require 'optparse'
require_relative 'version'
require_relative 'errors'
require_relative 'configuration'
require_relative 'project'
require_relative 'audit'
require_relative 'findings/severity'
require_relative 'reporters/text'
require_relative 'reporters/json'
require_relative 'static/rules/built_ins'

module FiberAudit
  # rubocop:disable Metrics/ModuleLength
  module CLI
    module_function

    def start(argv, stdout: $stdout, stderr: $stderr, cwd: Dir.pwd)
      args = argv.dup
      command = args.shift

      case command
      when 'static'
        run_static(args, stdout: stdout, stderr: stderr, cwd: cwd)
      when 'list-rules'
        reject_arguments!(args)
        list_rules(stdout)
      when 'explain'
        explain_rule(args, stdout: stdout, stderr: stderr)
      when 'version', '--version', '-v'
        reject_arguments!(args)
        stdout.puts "fiber-audit #{FiberAudit::VERSION}"
        0
      when nil
        print_help(stdout)
        0
      when 'help', '--help', '-h'
        reject_arguments!(args)
        print_help(stdout)
        0
      else
        raise OptionParser::InvalidArgument, "unknown command: #{command}"
      end
    rescue StandardError => e
      stderr.puts "fiber-audit: #{e.message}"
      2
    end

    def print_help(output = $stdout)
      output.puts <<~HELP
        Usage: fiber-audit <command> [options]

        Commands:
          static       Run static fiber-compatibility analysis
          list-rules   List all registered static rules
          explain ID   Explain a specific rule
          version      Print version
          help         Show this help

        Run `fiber-audit static --help` for analysis options.
      HELP
    end

    def run_static(argv, stdout:, stderr:, cwd:)
      options, parser = parse_static_options(argv)
      if options[:help]
        stdout.puts parser
        return 0
      end

      configuration, result = analyze_project(options, cwd, stderr)
      format = options[:format] || default_format(stdout, options[:out])
      report = render_report(format, result, color: color_enabled?(stdout, options))
      publish_report(report, options[:out], stdout, cwd)

      reportable_findings?(result.findings, configuration.min_severity) ? 1 : 0
    end

    def analyze_project(options, cwd, stderr)
      project = Project.detect(start_path: cwd)
      stderr.puts unknown_project_note(project) unless project.known?

      config_path = project.config_path(options[:config])
      if options[:config] && !File.file?(config_path)
        raise ConfigurationError, "configuration file does not exist: #{config_path}"
      end

      configuration = Configuration.load(config_path)
      configuration = with_min_severity(configuration, options[:min_severity]) if options[:min_severity]
      result = Audit.new(configuration: configuration, root: project.root).call
      [configuration, result]
    end

    def parse_static_options(argv)
      options = { format: nil, config: nil, out: nil, min_severity: nil, no_color: false, help: false }
      parser = OptionParser.new do |opts|
        opts.banner = 'Usage: fiber-audit static [options]'
        opts.on('--format FORMAT', %w[text json], 'Output format: text or json') { |value| options[:format] = value }
        opts.on('--config PATH', 'Path to configuration file') { |value| options[:config] = value }
        opts.on('--out PATH', 'Write report to a file') { |value| options[:out] = value }
        opts.on('--min-severity SEVERITY', Severity::LEVELS.map(&:to_s), 'Minimum reported severity') do |value|
          options[:min_severity] = value.to_sym
        end
        opts.on('--no-color', 'Disable ANSI colors') { options[:no_color] = true }
        opts.on('-h', '--help', 'Show static options') { options[:help] = true }
      end
      parser.parse!(argv)
      reject_arguments!(argv)
      [options, parser]
    end

    def with_min_severity(configuration, severity)
      Configuration.new(
        static_include: configuration.static_include,
        static_exclude: configuration.static_exclude,
        rules_config: configuration.rules_config,
        report_formats: configuration.report_formats,
        min_severity: severity,
        suppressions_path: configuration.suppressions_path
      )
    end

    def default_format(stdout, output_path)
      return 'json' if output_path

      stdout.respond_to?(:tty?) && stdout.tty? ? 'text' : 'json'
    end

    def color_enabled?(stdout, options)
      !options[:no_color] && !options[:out] && stdout.respond_to?(:tty?) && stdout.tty?
    end

    def render_report(format, result, color:)
      case format
      when 'text'
        Reporters::Text.new(color: color).render(result)
      when 'json'
        Reporters::JSON.new(pretty: true).render(result)
      else
        raise OptionParser::InvalidArgument, "unsupported format: #{format}"
      end
    end

    def publish_report(report, output_path, stdout, cwd)
      unless output_path
        stdout.write(report)
        return
      end

      resolved_path = File.expand_path(output_path, cwd)
      File.write(resolved_path, report)
      stdout.puts "Report written to #{output_path}"
    end

    def reportable_findings?(findings, minimum)
      findings.any? do |finding|
        Severity.index(finding.severity) <= Severity.index(minimum)
      end
    end

    def list_rules(stdout)
      Static::Rules::BuiltIns.registry.each do |rule_class|
        stdout.puts format('%<id>-7s %<severity>-8s %<description>s',
                           id: rule_class.id,
                           severity: rule_class.default_severity.to_s.upcase,
                           description: rule_class.description)
      end
      0
    end

    def explain_rule(argv, stdout:, stderr:)
      rule_id = argv.shift
      reject_arguments!(argv)
      unless rule_id
        stderr.puts 'Usage: fiber-audit explain <RULE_ID>'
        return 2
      end

      rule_class = Static::Rules::BuiltIns.registry.find(rule_id)
      unless rule_class
        stderr.puts "Unknown rule: #{rule_id}"
        return 2
      end

      stdout.puts "#{rule_class.id} — #{rule_title(rule_class)}"
      stdout.puts "Default severity: #{rule_class.default_severity}"
      stdout.puts "Default confidence: #{rule_class.default_confidence}"
      stdout.puts "Description: #{rule_class.description}"
      stdout.puts 'Targets:'
      rule_targets(rule_class).each { |target| stdout.puts "  - #{target}" }
      stdout.puts "Remediation: #{rule_class.const_get(:REMEDIATION)}"
      0
    end

    def rule_title(rule_class)
      return 'Blocking subprocess call' if rule_class.id == 'FA1001'

      %i[TITLE RULE_TITLE].each do |name|
        return rule_class.const_get(name) if rule_class.const_defined?(name, false)
      end
      rule_class.name.split('::').last
    end

    def rule_targets(rule_class)
      case rule_class.id
      when 'FA1001'
        expand_target_map(rule_class::TARGETS, '.')
      when 'FA1002'
        rule_class::TARGET_METHODS.map { |method| "Thread##{method}" }
      when 'FA1003'
        expand_target_map(rule_class::TARGETS, '#')
      when 'FA1004'
        rule_class::THREAD_VARIABLE_METHODS.map { |method| "Thread##{method}" } +
          rule_class::INDEX_METHODS.map { |method| "Thread.current.#{method}" }
      when 'FA1005'
        expand_target_map(rule_class::TARGETS.transform_values { |method| [method] }, '.')
      when 'FA1006'
        rule_class::EXACT.map { |constant| "#{constant}.new" } + ['IPSocket subclasses']
      when 'FA1007'
        rule_class::NET_HTTP_METHODS.map { |method| "Net::HTTP.#{method}" } +
          rule_class::URI_METHODS.map { |constant, method| "#{constant}.#{method}" }
      else
        []
      end
    end

    def expand_target_map(targets, separator)
      targets.flat_map do |constant, methods|
        Array(methods).map { |method| "#{constant}#{separator}#{method}" }
      end
    end

    def reject_arguments!(argv)
      return if argv.empty?

      raise OptionParser::InvalidArgument, "unexpected arguments: #{argv.join(' ')}"
    end

    def unknown_project_note(project)
      "Note: project root could not be detected; using #{project.root}"
    end
  end
  # rubocop:enable Metrics/ModuleLength
end
