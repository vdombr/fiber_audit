# frozen_string_literal: true

class ReassignmentExample
  def reassign_variable
    client = Redis.new
    client.get('key1')

    # Reassignment - should invalidate the tracking
    client = build_client
    client.get('key2')
  end

  def conditional_assignment
    if true
      client = Redis.new
    else
      client = build_client
    end
    # After conditional, we can't be certain what client is
    client.get('key')
  end
end
