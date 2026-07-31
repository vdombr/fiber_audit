# frozen_string_literal: true

module IncludedModule
  def module_method
    'from module'
  end
end

class ClassWithInclusion
  include IncludedModule

  def class_method
    'from class'
  end
end
