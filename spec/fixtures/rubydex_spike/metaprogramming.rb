# frozen_string_literal: true

class MetaprogrammingClass
  # Dynamic method definition
  define_method :dynamic_method do
    'dynamic_result'
  end

  # Class-level dynamic method
  define_singleton_method :class_dynamic_method do
    'class_dynamic_result'
  end

  # method_missing for dynamic dispatch
  def method_missing(method_name, *args, &block)
    if method_name.to_s.start_with?('dynamic_')
      "handled_#{method_name}"
    else
      super
    end
  end

  def respond_to_missing?(method_name, include_private = false)
    method_name.to_s.start_with?('dynamic_') || super
  end

  # attr_accessor creates methods dynamically
  attr_accessor :dynamic_attr

  # class_eval for dynamic class modification
  class_eval do
    define_method :eval_method do
      'eval_result'
    end
  end
end

# Module with metaprogramming
module MetaprogrammingModule
  def self.included(base)
    base.class_eval do
      define_method :included_method do
        'included_result'
      end
    end
  end
end

class MetaprogrammingUser
  include MetaprogrammingModule
end
