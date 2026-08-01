# frozen_string_literal: true

class SimpleClass
  def simple_method
    puts 'hello'
    Open3.capture3('ls')
  end
end
