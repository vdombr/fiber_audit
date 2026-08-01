# frozen_string_literal: true

module OuterModule
  class InnerClass
    def nested_method
      Net::HTTP.get('http://example.com')
    end
  end
end
