# frozen_string_literal: true

require 'fileutils'
require 'open3'
require 'rbconfig'
require 'tmpdir'

module FiberAuditSpecSupport
  module NativeGVLFixture
    SOURCE_DIRECTORY = File.expand_path('../fixtures/native_gvl', __dir__).freeze
    MAX_DIAGNOSTIC_BYTES = 4_096

    class Build
      attr_reader :directory, :require_path, :reason

      def initialize(directory:, require_path: nil, reason: nil)
        @directory = directory
        @require_path = require_path
        @reason = reason
      end

      def available? = !require_path.nil?

      def cleanup
        FileUtils.remove_entry(directory) if directory && File.exist?(directory)
      end
    end

    module_function

    def build
      directory = Dir.mktmpdir('fiber-audit-native-gvl')
      FileUtils.cp(File.join(SOURCE_DIRECTORY, 'extconf.rb'), directory)
      FileUtils.cp(File.join(SOURCE_DIRECTORY, 'native_gvl.c'), directory)

      extconf = run([RbConfig.ruby, 'extconf.rb'], directory)
      return unavailable(directory, 'extconf', extconf) unless extconf.fetch(:success)

      make_command = ENV.fetch('MAKE') do
        configured = RbConfig::CONFIG['MAKE'].to_s
        configured.empty? ? 'make' : configured
      end
      compilation = run([make_command], directory)
      return unavailable(directory, 'native compilation', compilation) unless compilation.fetch(:success)

      extension = Dir.glob(
        File.join(directory, "**/fiber_audit_native_gvl.#{RbConfig::CONFIG.fetch('DLEXT')}")
      ).first
      return Build.new(directory: directory, reason: 'native fixture build produced no extension') unless extension

      Build.new(directory: directory, require_path: extension.freeze)
    rescue SystemCallError => e
      Build.new(
        directory: directory,
        reason: "native fixture toolchain unavailable: #{e.class}"
      )
    end

    def run(command, directory)
      stdout, stderr, status = Open3.capture3(*command, chdir: directory)
      {
        success: status.success?,
        status: status.exitstatus,
        diagnostic: bounded_diagnostic(stdout, stderr)
      }.freeze
    end
    private_class_method :run

    def unavailable(directory, stage, result)
      diagnostic = result.fetch(:diagnostic)
      suffix = diagnostic.empty? ? '' : ": #{diagnostic}"
      Build.new(
        directory: directory,
        reason: "native fixture #{stage} failed with exit #{result.fetch(:status)}#{suffix}"
      )
    end
    private_class_method :unavailable

    def bounded_diagnostic(stdout, stderr)
      text = "#{stdout}\n#{stderr}".encode('UTF-8', invalid: :replace, undef: :replace, replace: '?')
      text.byteslice(-MAX_DIAGNOSTIC_BYTES, MAX_DIAGNOSTIC_BYTES).to_s.strip
    end
    private_class_method :bounded_diagnostic
  end
end
