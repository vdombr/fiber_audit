# frozen_string_literal: true

class MetaprogrammingClass
  define_method :dynamic_method do
    'dynamic'
  end

  def method_missing(name, *args)
    if name == :respond_to_missing
      true
    else
      super
    end
  end
end
