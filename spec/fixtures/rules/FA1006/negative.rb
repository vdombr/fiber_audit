# frozen_string_literal: true

# Wrong method — should not match (only .new is matched)
TCPSocket.open('localhost', 8080)
TCPServer.accept
UDPSocket.bind('0.0.0.0', 9000)

# Unrelated constants with .new — should not match
String.new('hello')
Array.new(3)
Hash.new
Object.new
Thread.new { :work }
IO.new(0)
