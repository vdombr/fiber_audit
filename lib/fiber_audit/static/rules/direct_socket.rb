# frozen_string_literal: true

require_relative 'base'
require_relative '../../findings/evidence'
require_relative '../../correlation/fingerprint'
require_relative '../../findings/finding'
require_relative '../../operation_semantics'
require_relative '../../operation_vocabulary'

module FiberAudit
  module Static
    module Rules
      # FA1006: Inventory and semantic classification for direct socket constructors.
      class DirectSocket < Base
        id 'FA1006'
        severity :low
        default_confidence :high
        description 'Direct socket constructors range from inventory-only allocation to endpoint setup.'

        TITLE = 'Direct socket construction'
        CATEGORY = :network
        EXACT = OperationVocabulary::FA1006_EXACT
        CATEGORY_METADATA = {
          socket_allocation: {
            title: 'Direct socket allocation',
            message: 'This constructor is inventory-level socket setup without a client connection; ' \
                     'later accept, connect, address resolution, or I/O may require scheduler cooperation.',
            remediation: 'Treat allocation as inventory and verify scheduler-aware behavior at later ' \
                         'accept, connect, resolution, and I/O calls.'
          },
          socket_resolve_connect: {
            title: 'Direct socket endpoint setup',
            message: 'This constructor may resolve an address and establish a network endpoint, requiring ' \
                     'scheduler cooperation from address-resolution and I/O hooks.',
            remediation: 'Verify address_resolve and scheduler-aware I/O hooks, and confirm runtime progress ' \
                         'for endpoint setup.'
          },
          socket_local_connect: {
            title: 'Direct local-socket connection',
            message: 'This constructor may establish a local socket connection and wait for endpoint progress.',
            remediation: 'Verify runtime progress for local-socket connection and move blocking setup outside ' \
                         'the fiber-scheduled path.'
          },
          socket_constructor_unknown: {
            title: 'Direct socket subclass construction',
            message: 'This IPSocket subclass constructor has unknown allocation/connect semantics and may ' \
                     'require scheduler cooperation.',
            remediation: 'Inspect the subclass constructor and verify scheduler-aware resolution, connection, ' \
                         'and I/O behavior.'
          }
        }.freeze

        class << self
          def title = TITLE
          def category = CATEGORY
        end

        def analyze(call_sites:)
          call_sites.filter_map { |site| match(site) }
        end

        private

        def match(site)
          return unless site.method_name == :new

          const = site.receiver_constant
          return unless const

          if EXACT.include?(const)
            return if shadowed?(const, site.nesting)

            return build_finding(site, const)
          end

          return unless ip_socket_subclass?(const)

          build_finding(site, const)
        end

        def shadowed?(name, nesting)
          sem = semantic_index
          return false unless sem

          !sem.resolve_constant(name, nesting: nesting || []).nil?
        rescue StandardError
          false
        end

        def ip_socket_subclass?(name)
          sem = semantic_index
          return false unless sem

          sem.ancestors_of(name).include?('IPSocket')
        rescue StandardError
          false
        end

        def semantic_index
          index = workspace.semantic_index if workspace.respond_to?(:semantic_index)
          index || workspace
        rescue StandardError
          nil
        end

        def build_finding(site, const)
          operation = "#{const}.new"
          profile = if EXACT.include?(const)
                      OperationSemantics.resolve(operation)
                    else
                      OperationSemantics.resolve_socket_constructor(operation)
                    end
          metadata = CATEGORY_METADATA.fetch(profile.category)

          Finding.new(
            rule_id: self.class.id,
            title: metadata.fetch(:title),
            category: self.class.category,
            severity: advisory_severity(:low),
            confidence: site.confidence,
            location: site.location,
            symbol: site.enclosing_symbol,
            operation: operation,
            execution_context: site.execution_context || :unknown,
            message: metadata.fetch(:message),
            evidence: [
              Evidence.new(
                source: 'static_analysis',
                message: "Matched #{operation} (#{profile.category})",
                details: {
                  receiver_constant: const,
                  method: :new,
                  semantic: profile.category,
                  wait_possible: profile.wait_possible,
                  inventory_only: profile.inventory_only,
                  scheduler_capability: profile.scheduler_capability
                }
              )
            ],
            remediation: metadata.fetch(:remediation)
          )
        end
      end
    end
  end
end
