# frozen_string_literal: true

require 'json'
require 'tmpdir'
require 'fiber_audit/runtime/environment'

RSpec.describe FiberAudit::Runtime::Environment do
  let(:launch_id) { '123e4567-e89b-42d3-a456-426614174000' }
  let(:policy) { FiberAudit::Runtime::Policy.new(sampling_rate: 0.75) }
  let(:operation_liveness_policy) do
    FiberAudit::Runtime::OperationLivenessPolicy.new(
      enabled: true,
      poll_interval_ms: 20,
      long_active_threshold_ms: 125
    )
  end

  let(:watchdog_policy) do
    FiberAudit::Runtime::WatchdogPolicy.new(
      enabled: true,
      heartbeat_interval_ms: 20,
      stall_threshold_ms: 125,
      max_frames: 7
    )
  end

  let(:process_progress_policy) do
    FiberAudit::Runtime::ProcessProgressPolicy.new(
      enabled: true,
      heartbeat_interval_ms: 20,
      stall_threshold_ms: 125,
      max_processes: 100,
      max_frames_per_poll: 30,
      max_buffer_bytes: 8_192
    )
  end

  def with_directories
    Dir.mktmpdir do |root|
      output = File.join(root, 'runtime output')
      Dir.mkdir(output)
      yield root, output
    end
  end

  it 'round-trips strict settings without unrelated or sensitive data' do
    with_directories do |root, output|
      settings = described_class.build(
        policy: policy,
        output_directory: output,
        project_root: root,
        launch_id: launch_id
      )
      encoded = described_class.dump(settings)
      environment = {
        described_class::ACTIVATION_KEY => '1',
        described_class::SETTINGS_KEY => encoded,
        described_class::FAILURE_MODE_KEY => 'open'
      }
      loaded = described_class.load(environment)
      payload = JSON.parse(encoded)

      expect(loaded).to eq(settings)
      expect(payload.keys).to eq(described_class::SETTINGS_KEYS)
      expect(payload.fetch('policy').keys).to eq(described_class::POLICY_KEYS)
      expect(payload.to_s).not_to include('command', 'hostname', 'SECRET')
      expect(encoded).to be_frozen
    end
  end

  it 'round-trips strict watchdog settings separately from session settings' do
    encoded = described_class.dump_watchdog_policy(watchdog_policy)
    loaded = described_class.load_watchdog_policy(described_class::WATCHDOG_SETTINGS_KEY => encoded)
    payload = JSON.parse(encoded)

    expect(loaded).to eq(watchdog_policy)
    expect(payload.keys).to eq(described_class::WATCHDOG_KEYS)
    expect(payload.to_s).not_to include('command', 'scheduler_class', 'SECRET')
    expect(encoded).to be_frozen
    expect(described_class.load_watchdog_policy({})).to equal(FiberAudit::Runtime::WatchdogPolicy::DISABLED)
  end

  it 'rejects malformed, unknown, and incompatible watchdog settings' do
    payload = JSON.parse(described_class.dump_watchdog_policy(watchdog_policy))
    invalid = [
      'malformed',
      JSON.generate(payload.merge('command' => 'secret')),
      JSON.generate(payload.except('max_frames')),
      JSON.generate(payload.merge('protocol_version' => 99))
    ]

    invalid.each do |value|
      expect do
        described_class.load_watchdog_policy(described_class::WATCHDOG_SETTINGS_KEY => value)
      end.to raise_error(FiberAudit::RuntimeContractError)
    end
  end

  it 'round-trips strict operation-liveness settings separately from session settings' do
    encoded = described_class.dump_operation_liveness_policy(operation_liveness_policy)
    loaded = described_class.load_operation_liveness_policy(
      described_class::OPERATION_LIVENESS_SETTINGS_KEY => encoded
    )
    payload = JSON.parse(encoded)

    expect(loaded).to eq(operation_liveness_policy)
    expect(payload.keys).to eq(described_class::OPERATION_LIVENESS_KEYS)
    expect(payload.to_s).not_to include('command', 'address', 'SECRET')
    expect(encoded).to be_frozen
    expect(described_class.load_operation_liveness_policy({}))
      .to equal(FiberAudit::Runtime::OperationLivenessPolicy::DISABLED)
  end

  it 'rejects malformed, unknown, missing, oversized, and incompatible liveness settings' do
    payload = JSON.parse(described_class.dump_operation_liveness_policy(operation_liveness_policy))
    invalid = [
      'malformed',
      JSON.generate(payload.merge('command' => 'secret')),
      JSON.generate(payload.except('long_active_threshold_ms')),
      JSON.generate(payload.merge('protocol_version' => 99)),
      'x' * (described_class::MAX_OPERATION_LIVENESS_SETTINGS_BYTES + 1)
    ]

    invalid.each do |value|
      expect do
        described_class.load_operation_liveness_policy(
          described_class::OPERATION_LIVENESS_SETTINGS_KEY => value
        )
      end.to raise_error(FiberAudit::RuntimeContractError)
    end
  end

  it 'includes an immutable strict liveness policy in the child environment delta' do
    with_directories do |root, output|
      settings = described_class.build(
        policy: policy,
        output_directory: output,
        project_root: root,
        launch_id: launch_id
      )
      child = described_class.child_environment(
        settings: settings,
        operation_liveness_policy: operation_liveness_policy,
        probes_enabled: true,
        base_environment: { 'SECRET' => 'do-not-copy' }
      )

      expect(described_class.load_operation_liveness_policy(child)).to eq(operation_liveness_policy)
      expect(child).not_to have_key('SECRET')
      expect(child.fetch(described_class::OPERATION_LIVENESS_SETTINGS_KEY)).to be_frozen
      expect(child).to be_frozen
    end
  end

  it 'rejects unknown, missing, malformed, and mismatched settings' do
    with_directories do |root, output|
      settings = described_class.build(
        policy: policy,
        output_directory: output,
        project_root: root,
        launch_id: launch_id
      )
      payload = JSON.parse(described_class.dump(settings))
      base = {
        described_class::ACTIVATION_KEY => '1',
        described_class::FAILURE_MODE_KEY => 'open'
      }

      unknown = payload.merge('command' => ['secret'])
      missing = payload.except('launch_id')
      [unknown, missing].each do |invalid|
        environment = base.merge(described_class::SETTINGS_KEY => JSON.generate(invalid))
        expect { described_class.load(environment) }.to raise_error(FiberAudit::RuntimeContractError)
      end

      expect { described_class.load(base.merge(described_class::SETTINGS_KEY => 'not base64!')) }
        .to raise_error(FiberAudit::RuntimeContractError)
      expect do
        described_class.load(
          base.merge(
            described_class::SETTINGS_KEY => described_class.dump(settings),
            described_class::FAILURE_MODE_KEY => 'closed'
          )
        )
      end.to raise_error(FiberAudit::RuntimeContractError, /failure mode/)
      expect do
        described_class.failure_mode(base.merge(described_class::FAILURE_MODE_KEY => 'sometimes'))
      end.to raise_error(FiberAudit::RuntimeContractError, /must be open or closed/)
    end
  end

  it 'builds an immutable child environment delta and preserves Ruby settings' do
    with_directories do |root, output|
      settings = described_class.build(
        policy: policy,
        output_directory: output,
        project_root: root,
        launch_id: launch_id
      )
      base = { 'RUBYOPT' => '-w', 'RUBYLIB' => '/existing/lib', 'SECRET' => 'do-not-copy' }
      original = base.dup
      library = File.join(root, 'library with spaces')

      child = described_class.child_environment(
        settings: settings,
        watchdog_policy: watchdog_policy,
        probes_enabled: true,
        base_environment: base,
        library_path: library
      )

      expect(child.fetch('RUBYOPT')).to eq("#{described_class::BOOT_REQUIRE} -w")
      expect(child.fetch('RUBYLIB')).to eq("#{library}#{File::PATH_SEPARATOR}/existing/lib")
      expect(described_class.load_watchdog_policy(child)).to eq(watchdog_policy)
      expect(described_class.probes_enabled?(child)).to be(true)
      expect(child.fetch(described_class::PROBES_KEY)).to eq('1')
      expect(child).not_to have_key('SECRET')
      expect(child).to be_frozen
      expect(base).to eq(original)
    end
  end

  it 'strictly validates explicit probe activation' do
    expect(described_class.probes_enabled?({})).to be(false)
    expect(described_class.probes_enabled?(described_class::PROBES_KEY => '1')).to be(true)
    expect do
      described_class.probes_enabled?(described_class::PROBES_KEY => 'yes')
    end.to raise_error(FiberAudit::RuntimeContractError, /must be 1/)

    with_directories do |root, output|
      settings = described_class.build(
        policy: policy,
        output_directory: output,
        project_root: root,
        launch_id: launch_id
      )
      expect do
        described_class.child_environment(settings: settings, probes_enabled: nil)
      end.to raise_error(FiberAudit::RuntimeContractError, /Boolean/)
    end
  end

  it 'deduplicates its exact RUBYOPT and RUBYLIB entries' do
    with_directories do |root, output|
      settings = described_class.build(
        policy: policy,
        output_directory: output,
        project_root: root,
        launch_id: launch_id
      )
      library = File.join(root, 'lib')
      base = {
        'RUBYOPT' => "#{described_class::BOOT_REQUIRE} -w",
        'RUBYLIB' => "#{library}#{File::PATH_SEPARATOR}/other"
      }

      child = described_class.child_environment(
        settings: settings,
        base_environment: base,
        library_path: library
      )
      expect(child.fetch('RUBYOPT').scan(described_class::BOOT_REQUIRE).size).to eq(1)
      expect(child.fetch('RUBYLIB').split(File::PATH_SEPARATOR).count(library)).to eq(1)
    end
  end

  it 'round-trips strict process-progress settings and a bounded numeric descriptor' do
    encoded = described_class.dump_process_progress_policy(process_progress_policy)
    environment = {
      described_class::PROCESS_PROGRESS_SETTINGS_KEY => encoded,
      described_class::PROCESS_PROGRESS_WRITER_FD_KEY => '9'
    }
    payload = JSON.parse(encoded)

    expect(described_class.load_process_progress_policy(environment)).to eq(process_progress_policy)
    expect(described_class.process_progress_writer_fd(environment)).to eq(9)
    expect(payload.keys).to eq(described_class::PROCESS_PROGRESS_KEYS)
    expect(payload.to_s).not_to include('command', 'argument', 'SECRET')
    expect(described_class.load_process_progress_policy({}))
      .to equal(FiberAudit::Runtime::ProcessProgressPolicy::DISABLED)
    expect(described_class.process_progress_writer_fd({})).to be_nil
  end

  it 'rejects malformed process-progress policy and writer-descriptor transport' do
    payload = JSON.parse(described_class.dump_process_progress_policy(process_progress_policy))
    invalid = [
      'malformed', JSON.generate(payload.merge('command' => 'secret')),
      JSON.generate(payload.except('max_processes')),
      JSON.generate(payload.merge('protocol_version' => 99)),
      'x' * (described_class::MAX_PROCESS_PROGRESS_SETTINGS_BYTES + 1)
    ]
    invalid.each do |value|
      expect do
        described_class.load_process_progress_policy(
          described_class::PROCESS_PROGRESS_SETTINGS_KEY => value
        )
      end.to raise_error(FiberAudit::RuntimeContractError)
    end
    %w[-1 2 12x 9999999].each do |value|
      expect do
        described_class.process_progress_writer_fd(
          described_class::PROCESS_PROGRESS_WRITER_FD_KEY => value
        )
      end.to raise_error(FiberAudit::RuntimeContractError)
    end
  end

  it 'attaches one immutable progress transport without mutating the base delta' do
    base = { described_class::ACTIVATION_KEY => '1' }.freeze
    attached = described_class.attach_process_progress_transport(
      base, policy: process_progress_policy, writer_fd: 9
    )

    expect(base).not_to have_key(described_class::PROCESS_PROGRESS_SETTINGS_KEY)
    expect(described_class.load_process_progress_policy(attached)).to eq(process_progress_policy)
    expect(described_class.process_progress_writer_fd(attached)).to eq(9)
    expect(attached).to be_frozen
    expect(attached.values).to all(be_frozen)
    expect do
      described_class.attach_process_progress_transport(
        attached, policy: process_progress_policy, writer_fd: 10
      )
    end.to raise_error(FiberAudit::RuntimeContractError, /already contains/)
  end

  it 'requires enabled policy and writer descriptor together' do
    with_directories do |root, output|
      settings = described_class.build(
        policy: policy, output_directory: output, project_root: root, launch_id: launch_id
      )
      expect do
        described_class.child_environment(settings: settings, process_progress_policy: process_progress_policy)
      end.to raise_error(FiberAudit::RuntimeContractError, /inherited writer descriptor/)
      expect do
        described_class.child_environment(
          settings: settings,
          process_progress_policy: FiberAudit::Runtime::ProcessProgressPolicy::DISABLED,
          process_progress_writer_fd: 9
        )
      end.to raise_error(FiberAudit::RuntimeContractError, /enabled policy/)
    end
  end

  it 'creates owner-only output directories without disturbing existing contents' do
    Dir.mktmpdir do |root|
      path = File.join(root, 'nested', 'runtime')
      expect(described_class.prepare_output_directory(path)).to eq(path)
      expect(File.stat(path).mode & 0o777).to eq(0o700)

      sentinel = File.join(path, 'keep')
      File.write(sentinel, 'present')
      expect(described_class.prepare_output_directory(path)).to eq(path)
      expect(File.read(sentinel)).to eq('present')

      file = File.join(root, 'not-a-directory')
      File.write(file, 'present')
      expect { described_class.prepare_output_directory(file) }
        .to raise_error(FiberAudit::RuntimeSafetyError, /not a directory/)
    end
  end
end
