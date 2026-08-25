# frozen_string_literal: true

blocking = true
Fiber.new(blocking: false) { Process.wait }
Fiber.new(blocking: blocking) { Process.wait }
Fiber.new { Process.wait }
CustomFiber.blocking { Process.wait }
blocking { Process.wait }
Fiber.new(blocking: true)
