# frozen_string_literal: true

module FiberAudit
  class ConfigurationError < StandardError; end
  class EmptyEvidenceError < StandardError; end
  class ReporterError < StandardError; end
  class ProjectError < StandardError; end
  class RuntimeContractError < ArgumentError; end
  class RuntimeSafetyError < StandardError; end
end
