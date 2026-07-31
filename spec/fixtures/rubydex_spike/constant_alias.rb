# frozen_string_literal: true

class Original
  def self.original_method
    'original_result'
  end

  def instance_method
    'instance_result'
  end
end

# Constant alias
Alias = Original

# Module alias
module OriginalModule
  def self.module_method
    'module_result'
  end
end

ModuleAlias = OriginalModule
