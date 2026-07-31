# frozen_string_literal: true

require_relative 'fiber_audit/version'
require_relative 'fiber_audit/errors'
require_relative 'fiber_audit/findings/severity'
require_relative 'fiber_audit/findings/confidence'
require_relative 'fiber_audit/findings/location'
require_relative 'fiber_audit/findings/evidence'
require_relative 'fiber_audit/correlation/fingerprint'
require_relative 'fiber_audit/findings/finding'
require_relative 'fiber_audit/findings/collection'
require_relative 'fiber_audit/configuration'
require_relative 'fiber_audit/suppressions/parser'
require_relative 'fiber_audit/suppressions/store'
require_relative 'fiber_audit/static/semantic_index'
require_relative 'fiber_audit/static/source_index'
require_relative 'fiber_audit/cli'

module FiberAudit
  # Public entry point — expanded as work packages are implemented
end
