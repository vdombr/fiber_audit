# frozen_string_literal: true

require 'spec_helper'

RSpec.describe FiberAudit::Collection do
  let(:location) { FiberAudit::Location.new(path: 'test.rb', line: 1, column: 0) }

  let(:evidence) do
    [FiberAudit::Evidence.new(source: :static, message: 'test evidence')]
  end

  def make_finding(rule_id:, severity:, **_extras)
    FiberAudit::Finding.new(
      rule_id: rule_id,
      category: :blocking_io,
      severity: severity,
      confidence: :confirmed,
      location: location,
      message: 'test finding',
      evidence: evidence
    )
  end

  def make_finding_without_evidence(rule_id:, **_extras)
    FiberAudit::Finding.new(
      rule_id: rule_id,
      category: :blocking_io,
      severity: :high,
      confidence: :confirmed,
      location: location,
      message: 'no evidence finding',
      evidence: []
    )
  end

  # ── WP-3R: constructor evidence invariant ──────────────────────────

  describe '.new (constructor)' do
    it 'raises EmptyEvidenceError when any initial finding has empty evidence' do
      good = make_finding(rule_id: 'FIB001', severity: :high)
      bad = make_finding_without_evidence(rule_id: 'FIB002')

      expect { described_class.new([good, bad]) }.to raise_error(
        FiberAudit::EmptyEvidenceError,
        /FIB002.*cannot be published without evidence/
      )
    end

    it 'raises EmptyEvidenceError when any initial finding has nil evidence' do
      bad = FiberAudit::Finding.new(
        rule_id: 'FIB003',
        category: :blocking_io,
        severity: :high,
        confidence: :confirmed,
        location: location,
        message: 'nil evidence',
        evidence: nil
      )

      expect { described_class.new([bad]) }.to raise_error(
        FiberAudit::EmptyEvidenceError,
        /FIB003.*cannot be published without evidence/
      )
    end

    it 'succeeds when all initial findings have evidence' do
      f1 = make_finding(rule_id: 'A', severity: :high)
      f2 = make_finding(rule_id: 'B', severity: :low)

      expect { described_class.new([f1, f2]) }.not_to raise_error
      expect(described_class.new([f1, f2]).size).to eq(2)
    end

    it 'succeeds with no arguments (empty collection)' do
      expect { described_class.new }.not_to raise_error
      expect(described_class.new).to be_empty
    end

    it 'succeeds with an empty array' do
      expect { described_class.new([]) }.not_to raise_error
      expect(described_class.new([])).to be_empty
    end
  end

  # ── WP-3R: input-array non-aliasing ────────────────────────────────

  describe 'input-array non-aliasing' do
    it 'does not share identity with the input array' do
      f = make_finding(rule_id: 'A', severity: :high)
      input = [f]
      collection = described_class.new(input)

      expect(collection.to_a).not_to equal(input)
    end

    it 'is not affected by mutations to the input array after construction' do
      f1 = make_finding(rule_id: 'A', severity: :high)
      f2 = make_finding(rule_id: 'B', severity: :low)
      input = [f1]
      collection = described_class.new(input)

      input << f2 # mutate the original array

      expect(collection.size).to eq(1)
      expect(collection.map(&:rule_id)).to eq(%w[A])
    end
  end

  # ── WP-3R: #add evidence enforcement ───────────────────────────────

  describe '#add' do
    it 'adds a finding to the collection' do
      collection = described_class.new
      finding = make_finding(rule_id: 'A', severity: :high)
      collection.add(finding)

      expect(collection.size).to eq(1)
      expect(collection.first).to equal(finding)
    end

    it 'returns self for chaining' do
      collection = described_class.new
      expect(collection.add(make_finding(rule_id: 'A', severity: :high))).to equal(collection)
    end

    it 'raises EmptyEvidenceError when evidence is empty' do
      collection = described_class.new
      finding = make_finding_without_evidence(rule_id: 'FIB001')

      expect { collection.add(finding) }.to raise_error(
        FiberAudit::EmptyEvidenceError,
        /FIB001.*cannot be published without evidence/
      )
    end

    it 'raises EmptyEvidenceError when evidence is nil' do
      collection = described_class.new
      finding = FiberAudit::Finding.new(
        rule_id: 'FIB002',
        category: :blocking_io,
        severity: :high,
        confidence: :confirmed,
        location: location,
        message: 'nil evidence finding',
        evidence: nil
      )

      expect { collection.add(finding) }.to raise_error(
        FiberAudit::EmptyEvidenceError,
        /FIB002.*cannot be published without evidence/
      )
    end

    it 'succeeds when evidence has at least one entry' do
      collection = described_class.new
      finding = FiberAudit::Finding.new(
        rule_id: 'FIB003',
        category: :blocking_io,
        severity: :high,
        confidence: :confirmed,
        location: location,
        message: 'with evidence',
        evidence: [FiberAudit::Evidence.new(source: :static, message: 'test')]
      )

      expect { collection.add(finding) }.not_to raise_error
      expect(collection.size).to eq(1)
    end

    it 'supports chaining multiple adds' do
      collection = described_class.new
      f1 = make_finding(rule_id: 'A', severity: :high)
      f2 = make_finding(rule_id: 'B', severity: :low)

      collection.add(f1).add(f2)

      expect(collection.size).to eq(2)
      expect(collection.map(&:rule_id)).to eq(%w[A B])
    end
  end

  # ── WP-3R: standalone require ──────────────────────────────────────

  describe 'standalone require' do
    it 'can be required without loading the full gem entry point' do
      # Verify the file declares its own dependency on fiber_audit/errors
      collection_source = File.read(
        File.expand_path('../../../../lib/fiber_audit/findings/collection.rb', __dir__)
      )
      expect(collection_source).to include("require 'fiber_audit/errors'")
    end

    it 'does not define EmptyEvidenceError itself (uses shared errors.rb)' do
      collection_source = File.read(
        File.expand_path('../../../../lib/fiber_audit/findings/collection.rb', __dir__)
      )
      expect(collection_source).not_to match(/class\s+EmptyEvidenceError/)
    end
  end

  # ── Preserved existing behavior ────────────────────────────────────

  describe '#each' do
    it 'iterates over all findings' do
      f1 = make_finding(rule_id: 'A', severity: :high)
      f2 = make_finding(rule_id: 'B', severity: :low)
      collection = described_class.new([f1, f2])

      expect(collection.map(&:rule_id)).to eq(%w[A B])
    end

    it 'is Enumerable' do
      collection = described_class.new
      expect(collection).to be_a(Enumerable)
    end
  end

  describe '#size' do
    it 'returns 0 for an empty collection' do
      expect(described_class.new.size).to eq(0)
    end

    it 'returns the number of findings' do
      f1 = make_finding(rule_id: 'A', severity: :high)
      f2 = make_finding(rule_id: 'B', severity: :low)
      expect(described_class.new([f1, f2]).size).to eq(2)
    end
  end

  describe '#empty?' do
    it 'returns true for an empty collection' do
      expect(described_class.new).to be_empty
    end

    it 'returns false when findings exist' do
      f = make_finding(rule_id: 'A', severity: :high)
      expect(described_class.new([f])).not_to be_empty
    end
  end

  describe '#by_rule' do
    it 'returns only findings matching the given rule_id' do
      f1 = make_finding(rule_id: 'FIB001', severity: :high)
      f2 = make_finding(rule_id: 'FIB002', severity: :medium)
      f3 = make_finding(rule_id: 'FIB001', severity: :low)
      collection = described_class.new([f1, f2, f3])

      result = collection.by_rule('FIB001')
      expect(result.size).to eq(2)
      expect(result.map(&:rule_id)).to eq(%w[FIB001 FIB001])
    end

    it 'returns an empty array when no findings match' do
      f = make_finding(rule_id: 'FIB001', severity: :high)
      collection = described_class.new([f])

      expect(collection.by_rule('FIB999')).to be_empty
    end
  end

  describe '#by_severity_min' do
    before do
      @f_critical = make_finding(rule_id: 'A', severity: :critical)
      @f_high     = make_finding(rule_id: 'B', severity: :high)
      @f_medium   = make_finding(rule_id: 'C', severity: :medium)
      @f_low      = make_finding(rule_id: 'D', severity: :low)
      @f_info     = make_finding(rule_id: 'E', severity: :info)
      @collection = described_class.new([@f_critical, @f_high, @f_medium, @f_low, @f_info])
    end

    it 'returns all findings when min is :info' do
      result = @collection.by_severity_min(:info)
      expect(result.size).to eq(5)
    end

    it 'returns only critical when min is :critical' do
      result = @collection.by_severity_min(:critical)
      expect(result.size).to eq(1)
      expect(result.first.severity).to eq(:critical)
    end

    it 'returns critical, high, and medium when min is :medium' do
      result = @collection.by_severity_min(:medium)
      expect(result.size).to eq(3)
      expect(result.map(&:severity)).to eq(%i[critical high medium])
    end

    it 'returns critical and high when min is :high' do
      result = @collection.by_severity_min(:high)
      expect(result.size).to eq(2)
      expect(result.map(&:severity)).to eq(%i[critical high])
    end
  end

  describe '#to_a' do
    it 'returns a duplicate of the internal array' do
      f = make_finding(rule_id: 'A', severity: :high)
      collection = described_class.new([f])
      arr = collection.to_a

      expect(arr.size).to eq(1)
      expect(arr).not_to equal(collection.to_a) # different array objects
    end
  end

  describe '#to_h_for_json' do
    it 'returns an array of hashes' do
      f1 = make_finding(rule_id: 'A', severity: :high)
      f2 = make_finding(rule_id: 'B', severity: :low)
      collection = described_class.new([f1, f2])

      result = collection.to_h_for_json
      expect(result).to be_an(Array)
      expect(result.size).to eq(2)
      expect(result.first).to be_a(Hash)
      expect(result.first[:rule_id]).to eq('A')
      expect(result.last[:rule_id]).to eq('B')
    end

    it 'returns an empty array for empty collection' do
      expect(described_class.new.to_h_for_json).to eq([])
    end
  end
end
