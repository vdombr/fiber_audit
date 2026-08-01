# frozen_string_literal: true

module FiberAudit
  # Execution context constants for classifying where code runs.
  #
  # These contexts represent the execution environment of a call site:
  # - request: ActionController handling an HTTP request
  # - middleware: Rack middleware in the request chain
  # - callback: ActiveRecord/ActiveSupport callback
  # - view: ActionView template rendering
  # - job: ActiveJob background job
  # - websocket: ActionCable WebSocket handler
  # - boot: Rails initializer or boot sequence
  # - console: Rails console or IRB session
  # - rake_task: Rake task execution
  # - test: Test suite (RSpec, Minitest)
  # - unknown: Cannot determine context
  #
  # The ALL array is frozen and ordered for iteration.
  module Context
    REQUEST    = :request
    MIDDLEWARE = :middleware
    CALLBACK   = :callback
    VIEW       = :view
    JOB        = :job
    WEBSOCKET  = :websocket
    BOOT       = :boot
    CONSOLE    = :console
    RAKE_TASK  = :rake_task
    TEST       = :test
    UNKNOWN    = :unknown

    ALL = [
      REQUEST,
      MIDDLEWARE,
      CALLBACK,
      VIEW,
      JOB,
      WEBSOCKET,
      BOOT,
      CONSOLE,
      RAKE_TASK,
      TEST,
      UNKNOWN
    ].freeze
  end
end
