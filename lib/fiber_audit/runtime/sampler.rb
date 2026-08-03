# frozen_string_literal: true

require_relative 'policy'

module FiberAudit
  module Runtime
    class Sampler
      RANDOM_SOURCE = -> { Random.rand }.freeze

      attr_reader :policy

      def initialize(policy:, random: RANDOM_SOURCE)
        raise RuntimeContractError, 'policy must be a FiberAudit::Runtime::Policy' unless policy.is_a?(Policy)
        raise RuntimeContractError, 'random source must respond to call' unless random.respond_to?(:call)

        @policy = policy
        @random = random
        freeze
      end

      def sample?
        policy.sample?(draw: @random.call)
      end
    end
  end
end
