# frozen_string_literal: true

require_relative 'errors'

module FiberAudit
  class Project
    MARKERS = %w[Gemfile gems.rb config/application.rb].freeze
    CONFIG_FILENAME = '.fiber-audit.yml'

    attr_reader :root, :invocation_path, :note

    def initialize(root:, invocation_path:, known:, note:)
      @root = root.freeze
      @invocation_path = invocation_path.freeze
      @known = known
      @note = note&.freeze
      freeze
    end

    def known?
      @known
    end

    def config_path(override = nil)
      if override
        resolve_override(override)
      else
        File.join(root, CONFIG_FILENAME)
      end
    end

    class << self
      def detect(start_path: Dir.pwd)
        validate_start_path(start_path)

        invocation_path = resolve_invocation_path(start_path)
        detected_root = find_project_root(invocation_path)

        if detected_root
          new(
            root: detected_root,
            invocation_path: invocation_path,
            known: true,
            note: nil
          )
        else
          new(
            root: invocation_path,
            invocation_path: invocation_path,
            known: false,
            note: :unknown_project
          )
        end
      end

      private

      def validate_start_path(path)
        return if File.exist?(path)

        raise ProjectError, "start_path does not exist: #{path}"
      end

      def resolve_invocation_path(start_path)
        expanded = File.expand_path(start_path)
        File.file?(start_path) ? File.dirname(expanded) : expanded
      end

      def find_project_root(start_dir)
        current = start_dir
        loop do
          return current if markers_present?(current)

          parent = File.dirname(current)
          return nil if parent == current

          current = parent
        end
      end

      def markers_present?(dir)
        MARKERS.any? { |marker| File.exist?(File.join(dir, marker)) }
      end
    end

    private

    def resolve_override(override)
      if File.absolute_path?(override)
        File.expand_path(override)
      else
        File.expand_path(override, invocation_path)
      end
    end
  end
end
