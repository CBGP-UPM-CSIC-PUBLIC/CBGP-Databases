# frozen_string_literal: true

# Covers CBGP::Loaders.mine_pending_orcids: the background-thread body a
# bulk DOI load spawns for its deferred ORCID-mining candidates
# (2026-10-16). Writes a found orcid to the member, updates the job's
# progress, then re-matches only the publications that actually gained a
# new orcid - merging into whatever cbgp_author_orcids already has, never
# only when it started empty (that exact gate was a confirmed real bug in
# utilities/rematch_xrefs_after_orcid_mining.rb until this same day).
RSpec.describe 'CBGP::Loaders.mine_pending_orcids' do
  let(:member_ds) { double('member dataset', primary_id: 'ana') }

  before do
    allow(CBGP::Dataset).to receive(:load_from_graph)
      .with(hash_including(database: 'member', graph: 'graph://member/1'))
      .and_return(member_ds)
    allow(member_ds).to receive(:orcid=)
    allow(CBGP::Dataset).to receive(:write_to_db)
  end

  it 'writes a mined orcid to the member and records a found result on the job' do
    allow(CBGP::Parsers).to receive(:mine_member_orcid)
      .with(hash_including(given: 'Ana', family: 'Ruiz')).and_return('0000-0001-1111-1111')
    job_id = CBGP::OrcidMiningJobs.create(total: 1)
    allow(CBGP::Loaders).to receive(:rematch_publication_xrefs)
    allow(CBGP::Parsers).to receive(:load_member_index).and_return([])

    CBGP::Loaders.mine_pending_orcids(
      candidates: [{ given: 'Ana', family: 'Ruiz', graph: 'graph://member/1', doi: '10.1/a' }],
      job_id: job_id, database: 'publication'
    )

    expect(member_ds).to have_received(:orcid=).with('0000-0001-1111-1111')
    expect(CBGP::Dataset).to have_received(:write_to_db).with(dataset: member_ds, oldid: 'ana')
    expect(CBGP::OrcidMiningJobs.status(job_id)).to include(searched: 1, found: 1, done: true)
    expect(CBGP::Loaders).to have_received(:rematch_publication_xrefs).with(hash_including(doi: '10.1/a'))
  end

  it 'records a not-found result and writes nothing when ORCID.org yields no confident match' do
    allow(CBGP::Parsers).to receive(:mine_member_orcid).and_return(nil)
    job_id = CBGP::OrcidMiningJobs.create(total: 1)
    allow(CBGP::Loaders).to receive(:rematch_publication_xrefs)

    CBGP::Loaders.mine_pending_orcids(
      candidates: [{ given: 'Ana', family: 'Ruiz', graph: 'graph://member/1', doi: '10.1/a' }],
      job_id: job_id, database: 'publication'
    )

    expect(member_ds).not_to have_received(:orcid=)
    expect(CBGP::OrcidMiningJobs.status(job_id)).to include(searched: 1, found: 0, done: true)
    expect(CBGP::Loaders).not_to have_received(:rematch_publication_xrefs)
  end

  it 'keeps the job progressing to done, treated as not-found, when mine_member_orcid raises for one candidate' do
    # A single candidate's failure (ORCID.org timeout, transient network
    # error) must not abandon the rest of the batch or leave the job
    # stuck at done: false forever - the bulk-load page polls this status
    # and would spin indefinitely.
    allow(CBGP::Parsers).to receive(:mine_member_orcid).and_raise(StandardError, 'ORCID.org unreachable')
    job_id = CBGP::OrcidMiningJobs.create(total: 1)

    expect do
      CBGP::Loaders.mine_pending_orcids(
        candidates: [{ given: 'Ana', family: 'Ruiz', graph: 'graph://member/1', doi: '10.1/a' }],
        job_id: job_id, database: 'publication'
      )
    end.not_to raise_error
    expect(CBGP::OrcidMiningJobs.status(job_id)).to include(searched: 1, found: 0, done: true)
    expect(member_ds).not_to have_received(:orcid=)
  end
end
