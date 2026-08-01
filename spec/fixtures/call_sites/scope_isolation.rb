# frozen_string_literal: true

class ScopeLeakExample
  def method_one
    client = Redis.new
    client.get('key')
  end

  def method_two
    # client should not be visible here
    # This is a bare call with no receiver
    puts 'test'
  end
end
