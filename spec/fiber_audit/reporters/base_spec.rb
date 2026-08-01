# frozen_string_literal: true

require 'fiber_audit/reporters/base'

RSpec.describe FiberAudit::Reporters::Base do
  describe '#render' do
    it 'raises NotImplementedError' do
      reporter = described_class.new
      expect { reporter.render(double('result')) }.to raise_error(NotImplementedError)
    end

    it 'includes class name in error message' do
      reporter = described_class.new
      expect { reporter.render(double('result')) }.to raise_error(
        NotImplementedError,
        /FiberAudit::Reporters::Base#render must be implemented/
      )
    end
  end
end
