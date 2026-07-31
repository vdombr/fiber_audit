# frozen_string_literal: true

module IncludedModule
  def module_method
    'module_result'
  end
end

class ClassWithInclusion
  include IncludedModule

  def class_method
    'class_result'
  end
end

module PrependedModule
  def prepended_method
    'prepended_result'
  end
end

class ClassWithPrepend
  prepend PrependedModule

  def own_method
    'own_result'
  end
end
