# frozen_string_literal: true

require 'spec_helper'
require 'fiber_audit/suppressions/parser'
require 'fiber_audit/configuration' # for ConfigurationError
require 'tmpdir'
require 'yaml'

RSpec.describe FiberAudit::Suppressions::Parser do
  describe 'standalone loading' do
    it 'can be required independently without the main loader' do
      cmd = 'ruby -Ilib -rfiber_audit/suppressions/parser' \
            ' -e "puts FiberAudit::Suppressions::Parser' \
            ".parse_inline('test.rb', '').inspect\""
      output = `#{cmd} 2>&1`
      status = $?
      expect(status).to be_success
      expect(output.strip).to eq('[]')
    end

    it 'explicitly requires errors.rb' do
      cmd = 'ruby -Ilib -rfiber_audit/suppressions/parser' \
            ' -e "puts FiberAudit::ConfigurationError"'
      output = `#{cmd} 2>&1`
      status = $?
      expect(status).to be_success
      expect(output.strip).to eq('FiberAudit::ConfigurationError')
    end
  end

  describe '.parse_inline' do
    context 'single-line form' do
      it 'parses inline disable comment on a code line' do
        content = <<~RUBY
          x = 1
          Open3.capture3(cmd) # fiber-audit:disable FA1001 -- runs in background job
          y = 2
        RUBY

        result = described_class.parse_inline(
          'app/services/worker.rb', content
        )

        expect(result.size).to eq(1)
        sup = result.first
        expect(sup).to be_a(
          FiberAudit::Suppressions::InlineSuppression
        )
        expect(sup.rule_id).to eq('FA1001')
        expect(sup.reason).to eq('runs in background job')
        expect(sup.path).to eq('app/services/worker.rb')
        expect(sup.start_line).to eq(2)
        expect(sup.end_line).to eq(2)
      end

      it 'parses multiple inline suppressions on different lines' do
        content = <<~RUBY
          system(cmd) # fiber-audit:disable FA1001 -- safe subprocess
          Thread.new { }.join # fiber-audit:disable FA1002 -- test only
        RUBY

        result = described_class.parse_inline('test.rb', content)

        expect(result.size).to eq(2)
        expect(result[0].rule_id).to eq('FA1001')
        expect(result[0].start_line).to eq(1)
        expect(result[1].rule_id).to eq('FA1002')
        expect(result[1].start_line).to eq(2)
      end
    end

    context 'block form' do
      it 'parses block disable/enable with correct span' do
        content = <<~RUBY
          x = 1
          # fiber-audit:disable FA1001 -- migration code
          system(cmd)
          Open3.capture3(cmd)
          # fiber-audit:enable FA1001
          y = 2
        RUBY

        result = described_class.parse_inline(
          'app/tasks/migrate.rb', content
        )

        expect(result.size).to eq(1)
        sup = result.first
        expect(sup.rule_id).to eq('FA1001')
        expect(sup.reason).to eq('migration code')
        expect(sup.path).to eq('app/tasks/migrate.rb')
        expect(sup.start_line).to eq(2)
        expect(sup.end_line).to eq(5)
      end

      it 'extends to end of file when no enable is found' do
        content = <<~RUBY
          # fiber-audit:disable FA1003 -- legacy locking
          mutex.synchronize { }
          another_mutex.lock
        RUBY

        result = described_class.parse_inline('legacy.rb', content)

        expect(result.size).to eq(1)
        sup = result.first
        expect(sup.rule_id).to eq('FA1003')
        expect(sup.start_line).to eq(1)
        expect(sup.end_line).to eq(3) # end of file
      end

      it 'correctly matches the enable for the right rule_id' do
        content = <<~RUBY
          # fiber-audit:disable FA1001 -- subprocess ok
          system(cmd)
          # fiber-audit:enable FA1001
          # fiber-audit:disable FA1002 -- join ok
          thread.join
          # fiber-audit:enable FA1002
        RUBY

        result = described_class.parse_inline('test.rb', content)

        expect(result.size).to eq(2)
        expect(result[0].rule_id).to eq('FA1001')
        expect(result[0].start_line).to eq(1)
        expect(result[0].end_line).to eq(3)
        expect(result[1].rule_id).to eq('FA1002')
        expect(result[1].start_line).to eq(4)
        expect(result[1].end_line).to eq(6)
      end
    end

    context 'missing reason' do
      it 'raises ConfigurationError for single-line without reason' do
        content = <<~RUBY
          x = 1 # fiber-audit:disable FA1001
        RUBY

        expect do
          described_class.parse_inline('test.rb', content)
        end.to raise_error(
          FiberAudit::ConfigurationError, /missing reason/
        )
      end

      it 'raises ConfigurationError for block form without reason' do
        content = <<~RUBY
          # fiber-audit:disable FA1001
          system(cmd)
        RUBY

        expect do
          described_class.parse_inline('test.rb', content)
        end.to raise_error(
          FiberAudit::ConfigurationError, /missing reason/
        )
      end
    end

    context 'non-matching lines' do
      it 'returns empty array for code without suppressions' do
        content = <<~RUBY
          class Foo
            def bar
              puts "hello"
            end
          end
        RUBY

        result = described_class.parse_inline('foo.rb', content)
        expect(result).to be_empty
      end

      it 'returns empty array for empty content' do
        result = described_class.parse_inline('empty.rb', '')
        expect(result).to be_empty
      end
    end

    context 'directives inside strings' do
      it 'does NOT create suppressions inside double-quoted strings' do
        content = <<~RUBY
          x = "fiber-audit:disable FA1001 -- inside string"
          y = 1
        RUBY

        result = described_class.parse_inline('test.rb', content)
        expect(result).to be_empty
      end

      it 'does NOT create suppressions inside single-quoted strings' do
        content = <<~RUBY
          x = 'fiber-audit:disable FA1001 -- inside string'
          y = 1
        RUBY

        result = described_class.parse_inline('test.rb', content)
        expect(result).to be_empty
      end
    end

    context 'directives inside heredocs' do
      it 'does NOT create suppressions for directives in heredocs' do
        content = <<~RUBY
          text = <<~HEREDOC
            fiber-audit:disable FA1001 -- inside heredoc
          HEREDOC
          y = 1
        RUBY

        result = described_class.parse_inline('test.rb', content)
        expect(result).to be_empty
      end

      it 'does NOT create suppressions in heredocs with interpolation' do
        content = <<~RUBY
          text = <<-HEREDOC
            fiber-audit:disable FA1002 -- also inside
          HEREDOC
          y = 2
        RUBY

        result = described_class.parse_inline('test.rb', content)
        expect(result).to be_empty
      end
    end

    context 'directives inside regex literals' do
      it 'does NOT create suppressions for directives in regex' do
        content = <<~RUBY
          x = /fiber-audit:disable FA1001 -- inside regex/
          y = 1
        RUBY

        result = described_class.parse_inline('test.rb', content)
        expect(result).to be_empty
      end

      it 'does NOT end blocks for enable directives inside regex' do
        content = <<~RUBY
          # fiber-audit:disable FA1001 -- legacy code
          system(cmd)
          x = /fiber-audit:enable FA1001/
          Open3.capture3(cmd)
          y = 1
        RUBY

        result = described_class.parse_inline('test.rb', content)
        expect(result.size).to eq(1)
        sup = result.first
        expect(sup.rule_id).to eq('FA1001')
        # Enable is in regex, not a comment: block extends to EOF
        expect(sup.end_line).to eq(5)
      end
    end

    context 'enable directives in strings do not end blocks' do
      it 'does NOT end blocks for enable in double-quoted strings' do
        content = <<~RUBY
          # fiber-audit:disable FA1001 -- legacy code
          system(cmd)
          x = "# fiber-audit:enable FA1001"
          Open3.capture3(cmd)
          y = 1
        RUBY

        result = described_class.parse_inline('test.rb', content)
        expect(result.size).to eq(1)
        sup = result.first
        expect(sup.rule_id).to eq('FA1001')
        # Enable is in string, not comment: block extends to EOF
        expect(sup.end_line).to eq(5)
      end

      it 'does NOT end blocks for enable directives inside heredocs' do
        content = <<~RUBY
          # fiber-audit:disable FA1002 -- test code
          Thread.new { }.join
          text = <<~HEREDOC
            # fiber-audit:enable FA1002
          HEREDOC
          another_thread.join
          y = 1
        RUBY

        result = described_class.parse_inline('test.rb', content)
        expect(result.size).to eq(1)
        sup = result.first
        expect(sup.rule_id).to eq('FA1002')
        # Enable is in heredoc, not comment: block extends to EOF
        expect(sup.end_line).to eq(7)
      end
    end

    context 'matching rule enables' do
      it 'matches enable by rule ID, not by order' do
        content = <<~RUBY
          # fiber-audit:disable FA1001 -- first
          # fiber-audit:disable FA1002 -- second
          code
          # fiber-audit:enable FA1001
          more_code
          # fiber-audit:enable FA1002
        RUBY

        result = described_class.parse_inline('test.rb', content)
        expect(result.size).to eq(2)

        fa1001 = result.find { |s| s.rule_id == 'FA1001' }
        fa1002 = result.find { |s| s.rule_id == 'FA1002' }

        expect(fa1001.start_line).to eq(1)
        expect(fa1001.end_line).to eq(4)
        expect(fa1002.start_line).to eq(2)
        expect(fa1002.end_line).to eq(6)
      end

      it 'handles multiple blocks for the same rule' do
        content = <<~RUBY
          # fiber-audit:disable FA1001 -- first block
          code1
          # fiber-audit:enable FA1001
          code2
          # fiber-audit:disable FA1001 -- second block
          code3
          # fiber-audit:enable FA1001
        RUBY

        result = described_class.parse_inline('test.rb', content)
        expect(result.size).to eq(2)

        expect(result[0].start_line).to eq(1)
        expect(result[0].end_line).to eq(3)
        expect(result[1].start_line).to eq(5)
        expect(result[1].end_line).to eq(7)
      end
    end

    context 'block vs trailing comment distinction' do
      it 'treats whitespace-only prefix as block comment' do
        content = <<~RUBY
            # fiber-audit:disable FA1001 -- reason
          code
          more_code
        RUBY

        result = described_class.parse_inline('test.rb', content)
        expect(result.size).to eq(1)
        sup = result.first
        expect(sup.rule_id).to eq('FA1001')
        # Block comment: extends to EOF since no enable
        expect(sup.end_line).to eq(3)
      end

      it 'treats comment with code before it as trailing comment' do
        content = <<~RUBY
          code1 # fiber-audit:disable FA1001 -- reason
          code2
        RUBY

        result = described_class.parse_inline('test.rb', content)
        expect(result.size).to eq(1)
        sup = result.first
        expect(sup.rule_id).to eq('FA1001')
        # Trailing: only suppresses the line it is on
        expect(sup.start_line).to eq(sup.end_line)
      end

      it 'distinguishes between block and trailing on lines' do
        content = <<~RUBY
          # fiber-audit:disable FA1001 -- block
          code1
          code2 # fiber-audit:disable FA1002 -- trailing
          code3
        RUBY

        result = described_class.parse_inline('test.rb', content)
        expect(result.size).to eq(2)

        block_sup = result.find { |s| s.rule_id == 'FA1001' }
        trailing_sup = result.find { |s| s.rule_id == 'FA1002' }

        # Block extends to EOF
        expect(block_sup.end_line).to eq(4)
        # Trailing only suppresses its own line
        expect(trailing_sup.start_line).to eq(
          trailing_sup.end_line
        )
      end
    end
  end

  describe '.parse_yaml' do
    it 'returns empty array when path is nil' do
      expect(described_class.parse_yaml(nil)).to eq([])
    end

    it 'returns empty array when file does not exist' do
      path = '/nonexistent/suppressions.yml'
      expect(described_class.parse_yaml(path)).to eq([])
    end

    it 'parses valid YAML suppressions' do
      yaml_content = {
        'suppressions' => [
          {
            'rule' => 'FA1001',
            'symbol' => 'DataMigration#run',
            'reason' => 'Offline task'
          },
          {
            'rule' => 'FA1003',
            'reason' => 'Known safe lock'
          }
        ]
      }

      Dir.mktmpdir do |dir|
        path = File.join(dir, 'suppressions.yml')
        File.write(path, YAML.dump(yaml_content))

        result = described_class.parse_yaml(path)

        expect(result.size).to eq(2)

        expect(result[0]).to be_a(
          FiberAudit::Suppressions::YamlSuppression
        )
        expect(result[0].rule).to eq('FA1001')
        expect(result[0].symbol).to eq('DataMigration#run')
        expect(result[0].operation).to be_nil
        expect(result[0].reason).to eq('Offline task')

        expect(result[1].rule).to eq('FA1003')
        expect(result[1].symbol).to be_nil
        expect(result[1].reason).to eq('Known safe lock')
      end
    end

    it 'parses YAML suppression with operation' do
      yaml_content = {
        'suppressions' => [
          {
            'rule' => 'FA1001',
            'operation' => 'Open3.capture3',
            'reason' => 'Wrapped safely'
          }
        ]
      }

      Dir.mktmpdir do |dir|
        path = File.join(dir, 'suppressions.yml')
        File.write(path, YAML.dump(yaml_content))

        result = described_class.parse_yaml(path)

        expect(result.size).to eq(1)
        expect(result[0].operation).to eq('Open3.capture3')
      end
    end

    it 'raises ConfigurationError when reason is missing' do
      yaml_content = {
        'suppressions' => [
          { 'rule' => 'FA1001', 'symbol' => 'Foo#bar' }
        ]
      }

      Dir.mktmpdir do |dir|
        path = File.join(dir, 'suppressions.yml')
        File.write(path, YAML.dump(yaml_content))

        expect do
          described_class.parse_yaml(path)
        end.to raise_error(
          FiberAudit::ConfigurationError, /missing 'reason'/
        )
      end
    end

    it 'raises ConfigurationError when reason is empty string' do
      yaml_content = {
        'suppressions' => [
          { 'rule' => 'FA1001', 'reason' => '   ' }
        ]
      }

      Dir.mktmpdir do |dir|
        path = File.join(dir, 'suppressions.yml')
        File.write(path, YAML.dump(yaml_content))

        expect do
          described_class.parse_yaml(path)
        end.to raise_error(
          FiberAudit::ConfigurationError, /missing 'reason'/
        )
      end
    end

    it 'returns empty array for empty suppressions list' do
      Dir.mktmpdir do |dir|
        path = File.join(dir, 'suppressions.yml')
        File.write(
          path,
          YAML.dump({ 'suppressions' => [] })
        )

        result = described_class.parse_yaml(path)
        expect(result).to eq([])
      end
    end
  end
end
