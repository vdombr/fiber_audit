# frozen_string_literal: true

require 'optparse'

module FiberAudit
  module CLI
    module_function

    def start(argv)
      command = argv.shift

      case command
      when 'static'
        run_static(argv)
      when 'list-rules'
        puts 'No rules registered yet (implementation pending)'
      when 'explain'
        puts 'Usage: fiber-audit explain <RULE_ID>'
      when 'version', '--version', '-v'
        puts "fiber-audit #{FiberAudit::VERSION}"
      when nil, 'help', '--help', '-h'
        print_help
      else
        warn "Unknown command: #{command}"
        print_help
        exit 2
      end
    end

    def print_help
      puts <<~HELP
        Usage: fiber-audit <command> [options]

        Commands:
          static       Run static fiber-compatibility analysis
          list-rules   List all registered static rules
          explain ID   Explain a specific rule
          version      Print version
          help         Show this help

        Static options:
          --format text|json   Output format (default: text)
          --config PATH        Path to .fiber-audit.yml
          --out PATH           Write report to file
          --min-severity SEV   Minimum severity to report (default: low)
          --no-color           Disable colored output
      HELP
    end

    def run_static(_argv)
      # Placeholder — will be implemented by WP-10
      puts 'Static analysis not yet implemented'
      exit 2
    end
  end
end
