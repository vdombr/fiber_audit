# frozen_string_literal: true

Fiber.new(blocking: true) do
  IO.select([], [], [], nil)
end

Fiber.blocking do
  worker = Thread.new { :done }
  worker.join
end

Fiber.new(blocking: true) do
  perform_cpu_only_work
end

Fiber.blocking do
  Net::HTTP.get(uri)
end
