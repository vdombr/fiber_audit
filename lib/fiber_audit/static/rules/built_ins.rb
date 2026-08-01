# frozen_string_literal: true

require_relative 'registry'
require_relative 'blocking_subprocess'
require_relative 'thread_join'
require_relative 'synchronization'
require_relative 'thread_current_state'
require_relative 'io_select'
require_relative 'direct_socket'
require_relative 'net_http_in_request'

module FiberAudit
  module Static
    module Rules
      module BuiltIns
        RULES = [
          BlockingSubprocess,
          ThreadJoin,
          Synchronization,
          ThreadCurrentState,
          IOSelect,
          DirectSocket,
          NetHTTPInRequest
        ].freeze

        module_function

        def registry(workspace: nil, context_resolver: nil)
          Registry.new(workspace: workspace, context_resolver: context_resolver).tap do |registry|
            RULES.each { |rule_class| registry.register(rule_class) }
          end
        end
      end
    end
  end
end
