# frozen_string_literal: true

# Covers CBGP::OrcidMiningJobs: the in-memory progress tracker a bulk DOI
# load's background ORCID-mining thread (lib/loaders.rb) updates, and the
# bulk-load page polls via GET /cbgp/publications/bulk/orcid_status/:job_id
# (2026-10-16).
RSpec.describe CBGP::OrcidMiningJobs do
  it 'creates a job with zero progress and returns a distinct id each time' do
    id_a = described_class.create(total: 3)
    id_b = described_class.create(total: 5)

    expect(id_a).not_to eq(id_b)
    expect(described_class.status(id_a)).to include(total: 3, searched: 0, found: 0, done: false)
  end

  it 'marks a job created with zero total as already done' do
    id = described_class.create(total: 0)

    expect(described_class.status(id)).to include(done: true)
  end

  it 'tracks searched and found counts as results come in, and flips done once total is reached' do
    id = described_class.create(total: 2)

    described_class.record_result(id, found: true)
    status = described_class.status(id)
    expect(status).to include(searched: 1, found: 1, done: false)

    described_class.record_result(id, found: false)
    status = described_class.status(id)
    expect(status).to include(searched: 2, found: 1, done: true)
  end

  it 'returns nil for an unknown job id, rather than raising' do
    expect(described_class.status('does-not-exist')).to be_nil
  end

  it 'silently ignores a result recorded against an unknown job id' do
    expect { described_class.record_result('does-not-exist', found: true) }.not_to raise_error
  end
end
