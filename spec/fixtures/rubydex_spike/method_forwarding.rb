# frozen_string_literal: true

require 'forwardable'

class DelegateTarget
  def target_method
    'target_result'
  end

  def another_method
    'another_result'
  end
end

class ForwarderClass
  extend Forwardable

  def initialize
    @target = DelegateTarget.new
  end

  def_delegator :@target, :target_method
  def_delegator :@target, :another_method
  def_delegators :@target, :target_method, :another_method
end
