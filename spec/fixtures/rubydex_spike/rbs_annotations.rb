# frozen_string_literal: true

# RBS-style type annotations (comments that describe types)
# These are not enforced by Ruby but are used by type checkers

class TypedClass
  # @return [String]
  def typed_method
    'typed_result'
  end

  # @param name [String]
  # @param age [Integer]
  # @return [Hash]
  def parameterized_method(name, age)
    { name: name, age: age }
  end

  # @type [Array[String]]
  CONSTANT_ARRAY = %w[a b c].freeze
end

# Sorbet-style type annotations
class SorbetStyleClass
  sig { returns(String) }
  def sig_method
    'sig_result'
  end
end
