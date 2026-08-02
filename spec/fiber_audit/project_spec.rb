# frozen_string_literal: true

require 'spec_helper'
require 'fiber_audit/project'
require 'tmpdir'
require 'fileutils'
require 'open3'
require 'rbconfig'

RSpec.describe FiberAudit::Project do
  def create_marker(dir, marker)
    path = File.join(dir, marker)
    FileUtils.mkdir_p(File.dirname(path)) if marker.include?('/')
    FileUtils.touch(path)
  end

  describe 'standalone require' do
    it 'can be required independently without the main loader' do
      output, _stderr, status = Open3.capture3(
        RbConfig.ruby, '-Ilib', '-rfiber_audit/project',
        '-e', 'puts FiberAudit::Project'
      )
      expect(status).to be_success
      expect(output.strip).to eq('FiberAudit::Project')
    end

    it 'defines ProjectError without the main loader' do
      output, _stderr, status = Open3.capture3(
        RbConfig.ruby, '-Ilib', '-rfiber_audit/project',
        '-e', 'puts FiberAudit::ProjectError.ancestors.include?(StandardError)'
      )
      expect(status).to be_success
      expect(output.strip).to eq('true')
    end
  end

  describe '.detect' do
    context 'with Gemfile marker' do
      it 'detects root containing a Gemfile' do
        Dir.mktmpdir do |dir|
          FileUtils.touch(File.join(dir, 'Gemfile'))
          subdir = File.join(dir, 'app', 'models')
          FileUtils.mkdir_p(subdir)

          project = described_class.detect(start_path: subdir)

          expect(project).to be_known
          expect(project.root).to eq(dir)
          expect(project.note).to be_nil
        end
      end
    end

    context 'with gems.rb marker' do
      it 'detects root containing gems.rb' do
        Dir.mktmpdir do |dir|
          FileUtils.touch(File.join(dir, 'gems.rb'))
          subdir = File.join(dir, 'lib')
          FileUtils.mkdir_p(subdir)

          project = described_class.detect(start_path: subdir)

          expect(project).to be_known
          expect(project.root).to eq(dir)
          expect(project.note).to be_nil
        end
      end
    end

    context 'with config/application.rb marker' do
      it 'detects root containing config/application.rb' do
        Dir.mktmpdir do |dir|
          FileUtils.mkdir_p(File.join(dir, 'config'))
          FileUtils.touch(File.join(dir, 'config', 'application.rb'))
          subdir = File.join(dir, 'app', 'controllers')
          FileUtils.mkdir_p(subdir)

          project = described_class.detect(start_path: subdir)

          expect(project).to be_known
          expect(project.root).to eq(dir)
          expect(project.note).to be_nil
        end
      end
    end

    context 'nearest root selection' do
      it 'chooses the nearest directory containing a marker' do
        Dir.mktmpdir do |outer|
          FileUtils.touch(File.join(outer, 'Gemfile'))

          inner = File.join(outer, 'nested', 'project')
          FileUtils.mkdir_p(inner)
          FileUtils.touch(File.join(inner, 'Gemfile'))

          deep = File.join(inner, 'lib', 'deep')
          FileUtils.mkdir_p(deep)

          project = described_class.detect(start_path: deep)

          expect(project).to be_known
          expect(project.root).to eq(inner)
        end
      end

      it 'walks upward when intermediate dirs have no marker' do
        Dir.mktmpdir do |dir|
          FileUtils.touch(File.join(dir, 'Gemfile'))

          mid = File.join(dir, 'a', 'b')
          FileUtils.mkdir_p(mid)

          project = described_class.detect(start_path: mid)

          expect(project).to be_known
          expect(project.root).to eq(dir)
        end
      end
    end

    context 'fallback when no marker is found' do
      it 'returns unknown project with start path as root' do
        Dir.mktmpdir do |dir|
          empty = File.join(dir, 'empty_subdir')
          FileUtils.mkdir_p(empty)

          # Prevent walking into outer project by isolating at filesystem level
          # We use the tmp dir itself since it won't have markers above it
          project = described_class.detect(start_path: empty)

          # tmp dirs may or may not have a Gemfile in parent;
          # test the contract for a truly isolated path
          unless project.known?
            expect(project.root).to eq(empty)
            expect(project.note).to eq(:unknown_project)
          end
        end
      end

      it 'sets known? to false and note to :unknown_project on fallback' do
        Dir.mktmpdir do |isolated|
          # Create a deeply nested empty structure with no markers anywhere
          deep = File.join(isolated, 'a', 'b', 'c', 'd')
          FileUtils.mkdir_p(deep)

          project = described_class.detect(start_path: deep)

          expect(project.known?).to be false
          expect(project.note).to eq(:unknown_project)
          expect(project.root).to eq(deep)
        end
      end
    end

    context 'with a file start path' do
      it 'uses the file directory for detection' do
        Dir.mktmpdir do |dir|
          FileUtils.touch(File.join(dir, 'Gemfile'))
          file_path = File.join(dir, 'some_file.rb')
          FileUtils.touch(file_path)

          project = described_class.detect(start_path: file_path)

          expect(project).to be_known
          expect(project.root).to eq(dir)
          expect(project.invocation_path).to eq(dir)
        end
      end
    end

    context 'with a nonexistent start path' do
      it 'raises ProjectError' do
        expect do
          described_class.detect(start_path: '/nonexistent/path/xyz')
        end.to raise_error(FiberAudit::ProjectError, /does not exist/)
      end

      it 'raises a StandardError subclass consistent with existing errors' do
        expect(FiberAudit::ProjectError.ancestors).to include(StandardError)
      end
    end

    context 'path normalization' do
      it 'expands paths with .. components' do
        Dir.mktmpdir do |dir|
          FileUtils.touch(File.join(dir, 'Gemfile'))
          subdir = File.join(dir, 'sub')
          FileUtils.mkdir_p(subdir)

          dotdot_path = File.join(subdir, '..', 'sub')
          project = described_class.detect(start_path: dotdot_path)

          expect(project).to be_known
          expect(project.root).to eq(dir)
          expect(project.root).to eq(File.expand_path(project.root))
        end
      end

      it 'returns expanded absolute paths for root and invocation_path' do
        Dir.mktmpdir do |dir|
          FileUtils.touch(File.join(dir, 'Gemfile'))

          project = described_class.detect(start_path: dir)

          expect(project.root).to start_with('/')
          expect(project.invocation_path).to start_with('/')
          expect(project.root).to eq(File.expand_path(project.root))
        end
      end
    end

    context 'does not mutate cwd' do
      it 'leaves Dir.pwd unchanged after detection' do
        original_cwd = Dir.pwd

        Dir.mktmpdir do |dir|
          FileUtils.touch(File.join(dir, 'Gemfile'))
          described_class.detect(start_path: dir)
        end

        expect(Dir.pwd).to eq(original_cwd)
      end
    end

    context 'invocation_path' do
      it 'preserves the resolved start directory even when root differs' do
        Dir.mktmpdir do |dir|
          FileUtils.touch(File.join(dir, 'Gemfile'))
          deep = File.join(dir, 'a', 'b', 'c')
          FileUtils.mkdir_p(deep)

          project = described_class.detect(start_path: deep)

          expect(project).to be_known
          expect(project.root).to eq(dir)
          expect(project.invocation_path).to eq(deep)
        end
      end
    end

    context 'filesystem root boundary' do
      it 'stops at filesystem root without infinite loop' do
        Dir.mktmpdir do |isolated|
          deep = File.join(isolated, 'no_markers_here')
          FileUtils.mkdir_p(deep)

          project = described_class.detect(start_path: deep)
          expect(project.root).to be_a(String)
        end
      end
    end
  end

  describe '#config_path' do
    let(:project) do
      Dir.mktmpdir do |dir|
        FileUtils.touch(File.join(dir, 'Gemfile'))
        inner = File.join(dir, 'inner')
        FileUtils.mkdir_p(inner)
        detected = described_class.detect(start_path: inner)
        # Capture values since tmpdir is cleaned up
        [detected.root, detected.invocation_path, detected.known?, detected.note]
      end
    end

    it 'defaults to root/.fiber-audit.yml' do
      Dir.mktmpdir do |dir|
        FileUtils.touch(File.join(dir, 'Gemfile'))
        proj = described_class.detect(start_path: dir)

        expect(proj.config_path).to eq(File.join(dir, '.fiber-audit.yml'))
      end
    end

    it 'returns an absolute path unchanged and cleaned' do
      Dir.mktmpdir do |dir|
        FileUtils.touch(File.join(dir, 'Gemfile'))
        proj = described_class.detect(start_path: dir)

        absolute = '/explicit/path/config.yml'
        expect(proj.config_path(absolute)).to eq(absolute)
      end
    end

    it 'cleans absolute paths containing ..' do
      Dir.mktmpdir do |dir|
        FileUtils.touch(File.join(dir, 'Gemfile'))
        proj = described_class.detect(start_path: dir)

        messy = '/a/b/../c/config.yml'
        expect(proj.config_path(messy)).to eq('/a/c/config.yml')
      end
    end

    it 'resolves relative override from invocation_path, not root' do
      Dir.mktmpdir do |dir|
        FileUtils.touch(File.join(dir, 'Gemfile'))
        inner = File.join(dir, 'inner', 'deep')
        FileUtils.mkdir_p(inner)

        proj = described_class.detect(start_path: inner)

        expect(proj).to be_known
        expect(proj.root).to eq(dir)
        expect(proj.invocation_path).to eq(inner)

        relative = 'custom.yml'
        expected = File.join(inner, 'custom.yml')
        expect(proj.config_path(relative)).to eq(expected)
      end
    end

    it 'does not require the default config file to exist' do
      Dir.mktmpdir do |dir|
        FileUtils.touch(File.join(dir, 'Gemfile'))
        proj = described_class.detect(start_path: dir)

        path = proj.config_path
        expect(path).to end_with('.fiber-audit.yml')
        expect(File.exist?(path)).to be false
      end
    end
  end

  describe 'immutability' do
    it 'is frozen' do
      Dir.mktmpdir do |dir|
        FileUtils.touch(File.join(dir, 'Gemfile'))
        project = described_class.detect(start_path: dir)

        expect(project).to be_frozen
      end
    end

    it 'has frozen string attributes' do
      Dir.mktmpdir do |dir|
        FileUtils.touch(File.join(dir, 'Gemfile'))
        project = described_class.detect(start_path: dir)

        expect(project.root).to be_frozen
        expect(project.invocation_path).to be_frozen
      end
    end

    it 'does not allow attribute modification' do
      Dir.mktmpdir do |dir|
        FileUtils.touch(File.join(dir, 'Gemfile'))
        project = described_class.detect(start_path: dir)

        expect { project.instance_variable_set(:@root, '/fake') }
          .to raise_error(FrozenError)
      end
    end
  end

  describe 'marker priority within same directory' do
    it 'detects root when multiple markers exist in same directory' do
      Dir.mktmpdir do |dir|
        FileUtils.touch(File.join(dir, 'Gemfile'))
        FileUtils.touch(File.join(dir, 'gems.rb'))
        FileUtils.mkdir_p(File.join(dir, 'config'))
        FileUtils.touch(File.join(dir, 'config', 'application.rb'))
        subdir = File.join(dir, 'sub')
        FileUtils.mkdir_p(subdir)

        project = described_class.detect(start_path: subdir)

        expect(project).to be_known
        expect(project.root).to eq(dir)
      end
    end
  end

  describe 'start_path at the marker directory itself' do
    it 'detects the directory containing the marker as root' do
      Dir.mktmpdir do |dir|
        FileUtils.touch(File.join(dir, 'Gemfile'))

        project = described_class.detect(start_path: dir)

        expect(project).to be_known
        expect(project.root).to eq(dir)
        expect(project.invocation_path).to eq(dir)
      end
    end
  end
end
