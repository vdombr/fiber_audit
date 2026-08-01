# frozen_string_literal: true

class ReassignmentExample
  def reassign_variable
    client = Redis.new
    client.get('key1')

    # Reassignment to builder - invalidates Redis tracking
    client = build_client
    client.get('key2')
  end

  def conditional_assignment
    # Branch-local assignments cannot leak after if/else
    if condition
      client = Redis.new
    else
      client = build_client
    end
    # After conditional, tracking is invalidated conservatively
    client.get('key3')
  end

  def condition
    true
  end

  def build_client
    Object.new
  end
end
