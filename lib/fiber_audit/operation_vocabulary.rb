# frozen_string_literal: true

module FiberAudit
  # Canonical operation names shared by static findings and runtime evidence.
  module OperationVocabulary
    FA1001_TARGETS = {
      'Kernel' => %i[system exec spawn].freeze,
      'Open3' => %i[capture2 capture2e capture3 pipeline].freeze,
      'IO' => %i[popen].freeze,
      'Process' => %i[spawn exec wait wait2 waitpid waitpid2 waitall detach].freeze,
      'Process::Status' => %i[wait].freeze
    }.freeze
    FA1001_KERNEL_METHODS = %i[system exec spawn].freeze

    FA1008_OPERATIONS = {
      fiber_new: 'Fiber.new(blocking: true)',
      fiber_blocking: 'Fiber.blocking'
    }.freeze

    FA1002_METHODS = %i[join value].freeze
    FA1002_OPERATIONS = %w[Thread.join Thread.value].freeze

    FA1003_TARGETS = {
      'Mutex' => %i[lock synchronize try_lock].freeze,
      'ConditionVariable' => %i[wait].freeze,
      'Monitor' => %i[synchronize].freeze,
      'MonitorMixin' => %i[synchronize].freeze
    }.freeze

    FA1004_THREAD_VARIABLE_METHODS = %i[thread_variable_get thread_variable_set].freeze
    FA1004_INDEX_METHODS = %i[[] []=].freeze

    FA1005_TARGETS = {
      'IO' => :select,
      'Kernel' => :select
    }.freeze

    FA1006_EXACT = %w[
      TCPSocket TCPServer UDPSocket UNIXSocket UNIXServer Socket IPSocket
    ].freeze

    FA1007_NET_HTTP_METHODS = %i[get get_response start request].freeze
    FA1007_URI_METHODS = {
      'URI' => :open,
      'OpenURI' => :open_uri
    }.freeze

    RUNTIME_SYNCHRONIZATION_OPERATIONS = {
      mutex_lock: 'Mutex#lock',
      mutex_synchronize: 'Mutex#synchronize',
      mutex_try_lock: 'Mutex#try_lock',
      mutex_unlock: 'Mutex#unlock',
      condition_wait: 'ConditionVariable#wait',
      condition_signal: 'ConditionVariable#signal',
      condition_broadcast: 'ConditionVariable#broadcast',
      monitor_enter: 'Monitor#enter',
      monitor_synchronize: 'Monitor#synchronize',
      monitor_try_enter: 'Monitor#try_enter',
      monitor_exit: 'Monitor#exit',
      monitor_mixin_enter: 'MonitorMixin#mon_enter',
      monitor_mixin_synchronize: 'MonitorMixin#synchronize',
      monitor_mixin_try_enter: 'MonitorMixin#mon_try_enter',
      monitor_mixin_exit: 'MonitorMixin#mon_exit',
      monitor_condition_wait: 'MonitorMixin::ConditionVariable#wait',
      monitor_condition_signal: 'MonitorMixin::ConditionVariable#signal',
      monitor_condition_broadcast: 'MonitorMixin::ConditionVariable#broadcast'
    }.freeze
  end
end
