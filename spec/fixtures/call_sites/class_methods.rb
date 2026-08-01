# frozen_string_literal: true

class ClassMethodsExample
  def instance_method
    Thread.new { sleep 1 }
  end

  def self.class_method
    Open3.capture3('echo test')
  end
end
