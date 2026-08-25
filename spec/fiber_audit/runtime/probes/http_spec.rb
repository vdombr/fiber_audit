# frozen_string_literal: true

require 'net/http'
require 'open-uri'
require 'socket'
require 'uri'
require_relative '../../../support/runtime_probe_harness'

RSpec.describe FiberAudit::Runtime::Probes::HTTP do
  after { stop_probe_runtime(@runtime) if @runtime }

  def with_http_server(body)
    server = TCPServer.new('127.0.0.1', 0)
    thread = Thread.new do
      client = server.accept
      loop do
        line = client.gets
        break if line.nil? || line == "\r\n"
      end
      client.write("HTTP/1.1 200 OK\r\nContent-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n#{body}")
      client.close
    end
    url = "http://127.0.0.1:#{server.addr[1]}/stage5-secret-path?token=secret-query"
    yield url
    thread.value
  ensure
    server&.close
    thread&.kill if thread&.alive?
    thread&.join
  end

  it 'preserves Net::HTTP singleton results without retaining URLs or bodies' do
    body = 'http-response-stage5-secret'
    with_http_server(body) do |url|
      @runtime = start_probe_runtime
      result = Net::HTTP.get(URI(url))

      expect(result).to eq(body)
      expect(operations(@runtime)).to include('Net::HTTP.get')
      expect(@runtime.io.string).not_to include('stage5-secret-path', 'secret-query', body, '127.0.0.1')
    end
  end

  it 'derives endpoint applicability without retaining URI or host values' do
    numeric = URI('http://127.0.0.1/private')
    named = URI('https://privacy-sentinel.example/private')

    expect(described_class.target_measurements(numeric)).to eq(endpoint_resolution_applicable: false)
    expect(described_class.target_measurements(named)).to eq(endpoint_resolution_applicable: true)
    expect(described_class.target_measurements(Object.new)).to eq(endpoint_resolution_applicable: nil)
    expect(described_class.target_measurements(named).to_s).not_to include('privacy-sentinel')

    http = Net::HTTP.new('privacy-sentinel.example', 80)
    expect(described_class.connection_measurements(http)).to eq(endpoint_resolution_applicable: true)
    http.instance_variable_set(:@started, true)
    expect(described_class.connection_measurements(http)).to eq(endpoint_resolution_applicable: false)
  end

  it 'preserves Net::HTTP.get_response objects' do
    body = 'get-response-stage5-secret'
    with_http_server(body) do |url|
      @runtime = start_probe_runtime
      response = Net::HTTP.get_response(URI(url))

      expect(response.body).to eq(body)
      expect(operations(@runtime)).to include('Net::HTTP.get_response')
      expect(@runtime.io.string).not_to include(body, 'stage5-secret-path')
    end
  end

  it 'preserves instance request blocks, keywords, headers, and response objects' do
    body = 'instance-http-stage5-secret'
    with_http_server(body) do |url|
      @runtime = start_probe_runtime
      uri = URI(url)
      request = Net::HTTP::Get.new(uri)
      request['X-Stage5-Secret'] = 'header-stage5-secret'
      response = Net::HTTP.start(uri.host, uri.port) { |http| http.request(request) }

      expect(response.body).to eq(body)
      expect(operations(@runtime)).to include('Net::HTTP.start', 'Net::HTTP.request')
      expect(@runtime.io.string).not_to include('header-stage5-secret', body, uri.host)
    end
  end

  it 'observes URI and OpenURI HTTP entry points but excludes non-HTTP targets' do
    body = 'open-uri-stage5-secret'
    with_http_server(body) do |url|
      @runtime = start_probe_runtime
      # rubocop:disable Security/Open -- this is the API under test.
      expect(URI.open(url, &:read)).to eq(body)
      # rubocop:enable Security/Open
    end
    first_operations = operations(@runtime)
    stop_probe_runtime(@runtime)
    @runtime = nil

    with_http_server(body) do |url|
      @runtime = start_probe_runtime
      expect(OpenURI.open_uri(url, &:read)).to eq(body)
    end

    expect(first_operations).to include('URI.open')
    expect(operations(@runtime)).to include('OpenURI.open_uri')
    expect(described_class.http_target?('file:///tmp/stage5-secret')).to be(false)
    expect(described_class.http_target?(Object.new)).to be(false)
    expect(@runtime.io.string).not_to include('open-uri-stage5-secret', 'stage5-secret-path')
  end

  it 're-raises connection exceptions without serializing messages' do
    server = TCPServer.new('127.0.0.1', 0)
    port = server.addr[1]
    server.close
    @runtime = start_probe_runtime
    error = nil

    begin
      Net::HTTP.get(URI("http://127.0.0.1:#{port}/connection-secret"))
    rescue SystemCallError => e
      error = e
    end

    expect(error).to be_a(SystemCallError)
    event = probe_events(@runtime).find { |record| record.dig('payload', 'operation') == 'Net::HTTP.get' }
    expect(event.dig('payload', 'kind')).to eq('operation_aborted')
    expect(@runtime.io.string).not_to include('connection-secret', '127.0.0.1', error.message)
  end
end
