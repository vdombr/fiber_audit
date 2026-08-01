# frozen_string_literal: true

# All seven exact socket constants used with .new
TCPSocket.new('localhost', 8080)
TCPServer.new(9090)
UDPSocket.new
UNIXSocket.new('/tmp/sock')
UNIXServer.new('/tmp/server')
Socket.new(:INET, :STREAM)
IPSocket.new
