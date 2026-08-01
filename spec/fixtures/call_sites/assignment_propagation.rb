# frozen_string_literal: true

class AssignmentExample
  def method_with_redis
    client = Redis.new
    client.get('key')
    client.set('key', 'value')
  end

  def method_with_builder
    conn = build_connection
    conn.execute('SELECT 1')
  end
end
