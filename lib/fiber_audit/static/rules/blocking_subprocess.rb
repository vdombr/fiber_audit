# frozen_string_literal: true

require_relative 'base'
require_relative '../../findings/evidence'
require_relative '../../correlation/fingerprint'
require_relative '../../findings/finding'
require_relative '../../operation_vocabulary'

module FiberAudit
  module Static
    module Rules
      # FA1001: Subprocess lifecycle operations that may interfere with
      # the fiber scheduler. Detects subprocess creation, replacement,
      # waiting, detachment, and stream lifecycle operations.
      #
      # Operations are classified into semantic categories:
      # - creation: spawning a new process (info)
      # - replacement: replacing the current process via exec (info)
      # - waiting: blocking waits for subprocess completion (medium)
      # - detach: detaching a subprocess without waiting (info)
      # - stream: subprocess pipe/stream lifecycle via IO.popen (medium)
      #
      # Severity: info for creation/replacement/detach, medium for waits/stream.
      # Context ceiling still applies (non-advisory rule).
      class BlockingSubprocess < Base
        id 'FA1001'
        severity :medium
        default_confidence :high
        description 'Subprocess lifecycle operations may interfere with the fiber scheduler'

        TARGETS = OperationVocabulary::FA1001_TARGETS
        BARE_KERNEL_METHODS = OperationVocabulary::FA1001_KERNEL_METHODS

        # Per-operation semantic category
        OPERATION_CATEGORY = {
          # Creation (info) - spawning a new process
          'Kernel.spawn' => :creation,
          'Process.spawn' => :creation,
          # Replacement (info) - replacing current process via exec
          'Kernel.exec' => :replacement,
          'Process.exec' => :replacement,
          # Waiting (medium) - blocking waits for subprocess completion
          'Kernel.system' => :waiting,
          'Process.wait' => :waiting,
          'Process.wait2' => :waiting,
          'Process.waitpid' => :waiting,
          'Process.waitpid2' => :waiting,
          'Process.waitall' => :waiting,
          'Process::Status.wait' => :waiting,
          'Open3.capture2' => :waiting,
          'Open3.capture2e' => :waiting,
          'Open3.capture3' => :waiting,
          'Open3.pipeline' => :waiting,
          # Detach (info) - detaching subprocess without waiting
          'Process.detach' => :detach,
          # Stream (medium) - subprocess pipe/stream lifecycle
          'IO.popen' => :stream
        }.freeze

        # Per-category metadata
        CATEGORY_METADATA = {
          creation: {
            severity: :info,
            title: 'Subprocess creation',
            message: 'Spawning a subprocess may leave background processes that outlive the fiber scheduler session.',
            remediation: 'Track spawned processes or move subprocess creation outside the fiber-scheduled path.'
          },
          replacement: {
            severity: :info,
            title: 'Process replacement',
            message: 'Process replacement via exec replaces the current process image, terminating the fiber scheduler.',
            remediation: 'Avoid exec in fiber-scheduled code; prefer subprocess creation with explicit lifecycle management.'
          },
          waiting: {
            severity: :medium,
            title: 'Subprocess wait',
            message: 'Waiting for a subprocess may block the thread running the fiber scheduler.',
            remediation: 'Use scheduler-aware subprocess APIs or move waits outside the fiber-scheduled path.'
          },
          detach: {
            severity: :info,
            title: 'Subprocess detach',
            message: 'Detaching a subprocess may leave it unmanaged by the fiber scheduler.',
            remediation: 'Avoid detaching subprocesses in fiber-scheduled code; use explicit lifecycle management.'
          },
          stream: {
            severity: :medium,
            title: 'Subprocess pipe stream',
            message: 'Subprocess pipe I/O may block the fiber scheduler thread while the stream is open.',
            remediation: 'Use scheduler-aware I/O on the pipe, or move pipe operations outside the fiber-scheduled path.'
          }
        }.freeze

        def analyze(call_sites:)
          call_sites.filter_map do |site|
            next unless (match = match_call_site(site))

            build_finding(site, match)
          end
        end

        private

        def match_call_site(site)
          receiver = site.receiver_constant
          method = site.method_name

          if receiver.nil? && site.receiver_source.nil? && BARE_KERNEL_METHODS.include?(method)
            return { constant: 'Kernel', method: method, confidence: :unknown }
          end

          return nil unless receiver && TARGETS.key?(receiver)
          return nil unless TARGETS[receiver].include?(method)
          return nil if shadowed?(receiver, site.nesting)

          { constant: receiver, method: method, confidence: site.confidence }
        end

        def shadowed?(constant_name, nesting)
          sem = workspace.semantic_index if workspace.respond_to?(:semantic_index)
          sem ||= workspace if workspace.respond_to?(:resolve_constant)
          return false unless sem.respond_to?(:resolve_constant)

          resolved = sem.resolve_constant(constant_name, nesting: nesting || [])
          !resolved.nil?
        rescue StandardError
          false
        end

        def build_finding(site, match)
          operation = "#{match[:constant]}.#{match[:method]}"
          context = site.execution_context || :unknown
          category = OPERATION_CATEGORY.fetch(operation, :waiting)
          metadata = CATEGORY_METADATA.fetch(category)
          base_severity = metadata[:severity]
          sev = severity_for(base_severity, context)

          Finding.new(
            rule_id: self.class.id,
            title: metadata[:title],
            category: :subprocess,
            severity: sev,
            confidence: match[:confidence],
            location: site.location,
            symbol: site.enclosing_symbol,
            operation: operation,
            execution_context: context,
            message: metadata[:message],
            evidence: [
              Evidence.new(
                source: :static,
                message: "Matched #{operation} (#{category})",
                details: {
                  receiver: match[:constant],
                  method: match[:method],
                  semantic: category
                }
              )
            ],
            remediation: metadata[:remediation]
          )
        end
      end
    end
  end
end
