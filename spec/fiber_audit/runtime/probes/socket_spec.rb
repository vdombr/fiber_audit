# frozen_string_literal: true

require 'socket'
require 'tmpdir'
require_relative '../../../support/runtime_probe_harness'

RSpec.describe FiberAudit::Runtime::Probes::Socket do
  after do
    stop_probe_runtime(@runtime) if @runtime
    Object.send(:remove_const, :FiberAuditStage5IPSocket) if Object.const_defined?(:FiberAuditStage5IPSocket, false)
  end

  it 'preserves exact socket constructors without serializing addresses or ports' do
    @runtime = start_probe_runtime
    socket = Socket.new(Socket::AF_INET, Socket::SOCK_STREAM, 0)
    udp = UDPSocket.new
    server = TCPServer.new('127.0.0.1', 0)

    expect(socket).to be_a(Socket)
    expect(udp).to be_a(UDPSocket)
    expect(server).to be_a(TCPServer)
    expect(operations(@runtime)).to include('Socket.new', 'UDPSocket.new', 'TCPServer.new')
    expect(@runtime.io.string).not_to include('127.0.0.1')
  ensure
    socket&.close
    udp&.close
    server&.close
  end

  it 'preserves TCP connection construction and never stores endpoint data' do
    server = TCPServer.new('127.0.0.1', 0)
    acceptor = Thread.new { server.accept }
    @runtime = start_probe_runtime

    client = TCPSocket.new('127.0.0.1', server.addr[1])
    accepted = acceptor.value

    expect(client).to be_a(TCPSocket)
    expect(operations(@runtime)).to include('TCPSocket.new')
    expect(@runtime.io.string).not_to include('127.0.0.1')
  ensure
    client&.close
    accepted&.close
    server&.close
    acceptor&.kill if acceptor&.alive?
    acceptor&.join
  end

  it 'covers UNIX constructors when the platform supports them' do
    skip 'UNIX sockets are unavailable' unless defined?(UNIXServer) && defined?(UNIXSocket)

    Dir.mktmpdir do |directory|
      path = File.join(directory, 'stage5-secret.sock')
      server = UNIXServer.new(path)
      acceptor = Thread.new { server.accept }
      @runtime = start_probe_runtime
      client = UNIXSocket.new(path)
      accepted = acceptor.value

      expect(client).to be_a(UNIXSocket)
      expect(operations(@runtime)).to include('UNIXSocket.new')
      stop_probe_runtime(@runtime)
      @runtime = start_probe_runtime
      second_path = File.join(directory, 'stage5-secret-server.sock')
      second_server = UNIXServer.new(second_path)
      expect(operations(@runtime)).to include('UNIXServer.new')
      expect(@runtime.io.string).not_to include('stage5-secret-server.sock')
    ensure
      client&.close
      accepted&.close
      server&.close
      second_server&.close unless second_server&.closed?
      acceptor&.kill if acceptor&.alive?
      acceptor&.join
    end
  end

  it 'records the exact IPSocket constructor failure without changing it' do
    @runtime = start_probe_runtime

    expect do
      IPSocket.new(Socket::AF_INET, Socket::SOCK_STREAM, 0)
    end.to raise_error(NoMethodError)
    event = probe_events(@runtime).find { |record| record.dig('payload', 'operation') == 'IPSocket.new' }
    expect(event.dig('payload', 'kind')).to eq('operation_aborted')
  end

  it 'uses a safe canonical name for a resolvable IPSocket subclass' do
    Object.const_set(:FiberAuditStage5IPSocket, Class.new(IPSocket))
    @runtime = start_probe_runtime

    expect do
      FiberAuditStage5IPSocket.new(Socket::AF_INET, Socket::SOCK_STREAM, 0)
    end.to raise_error(NoMethodError)

    event = probe_events(@runtime).find do |record|
      record.dig('payload', 'operation') == 'FiberAuditStage5IPSocket.new'
    end
    expect(event.dig('payload', 'kind')).to eq('operation_aborted')
  end

  it 'does not invent operations for anonymous or non-IP socket subclasses' do
    @runtime = start_probe_runtime
    anonymous = Class.new(IPSocket)
    unix_subclass = Class.new(UNIXSocket) if defined?(UNIXSocket)

    expect do
      anonymous.new(Socket::AF_INET, Socket::SOCK_STREAM, 0)
    end.to raise_error(NoMethodError)
    expect(operations(@runtime)).not_to include('[redacted].new')
    if unix_subclass
      expect { unix_subclass.allocate }.not_to raise_error
      expect(operations(@runtime).grep(/\.new\z/)).not_to include('UNIXSocket.new')
    end
  end
end
