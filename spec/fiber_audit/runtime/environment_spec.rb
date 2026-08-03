# frozen_string_literal: true

require 'json'
require 'tmpdir'
require 'fiber_audit/runtime/environment'

RSpec.describe FiberAudit::Runtime::Environment do
  let(:launch_id) { '123e4567-e89b-42d3-a456-426614174000' }
  let(:policy) { FiberAudit::Runtime::Policy.new(sampling_rate: 0.75) }

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
        base_environment: base,
        library_path: library
      )

      expect(child.fetch('RUBYOPT')).to eq("#{described_class::BOOT_REQUIRE} -w")
      expect(child.fetch('RUBYLIB')).to eq("#{library}#{File::PATH_SEPARATOR}/existing/lib")
      expect(child).not_to have_key('SECRET')
      expect(child).to be_frozen
      expect(base).to eq(original)
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
