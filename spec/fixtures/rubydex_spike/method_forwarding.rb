# frozen_string_literal: true

class Target
  def target_method
    'target'
  end
end

class Forwarder
  def initialize
    @target = Target.new
  end

  def forward_method
    @target.target_method
  end
end
