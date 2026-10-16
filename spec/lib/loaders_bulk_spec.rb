# frozen_string_literal: true

# Covers CBGP::Loaders.bulk_load_from_dois's ORCID-mining deferral
# (2026-10-16): a bulk load must never run the slow ORCID.org search
# inline (confirmed live, ~2.7s per author - a bulk load with several
# unresolved authors could take minutes and risk an HTTP/reverse-proxy
# timeout). It calls load_or_fetch_doi with mine_missing_orcids: false and
# collects whatever pending candidates come back, then hands them to a
# background job instead.
RSpec.describe 'CBGP::Loaders.bulk_load_from_dois' do
  before do
    allow(CBGP::Parsers).to receive(:load_member_index).and_return([])
    # The background thread itself is covered separately (mine_pending_
    # orcids); stubbing Thread.new to run inline here keeps this example
    # deterministic without actually spawning and racing a real thread.
    allow(Thread).to receive(:new) { |&blk| blk.call }
    allow(CBGP::Loaders).to receive(:mine_pending_orcids)
  end

  it 'creates no job and returns nil/0 when no DOI has a pending orcid candidate' do
    allow(CBGP::Loaders).to receive(:load_or_fetch_doi)
      .and_return({ pub: double('pub'), existing: false, pending_orcid_candidates: [] })

    _allpubs, _messages, job_id, estimated_seconds = CBGP::Loaders.bulk_load_from_dois(dois: "10.1/a\n10.1/b")

    expect(job_id).to be_nil
    expect(estimated_seconds).to eq(0)
  end

  it 'creates a job sized to the de-duplicated candidate count and a non-zero estimate when candidates are pending' do
    candidate_a = { given: 'Ana', family: 'Ruiz', graph: 'graph://member/1', doi: '10.1/a' }
    candidate_b = { given: 'Ana', family: 'Ruiz', graph: 'graph://member/1', doi: '10.1/b' } # same member, 2nd paper
    candidate_c = { given: 'Luis', family: 'Soto', graph: 'graph://member/2', doi: '10.1/b' }
    allow(CBGP::Loaders).to receive(:load_or_fetch_doi)
      .and_return({ pub: double('pub'), existing: false, pending_orcid_candidates: [candidate_a] },
                   { pub: double('pub'), existing: false, pending_orcid_candidates: [candidate_b, candidate_c] })

    _allpubs, _messages, job_id, estimated_seconds = CBGP::Loaders.bulk_load_from_dois(dois: "10.1/a\n10.1/b")

    expect(job_id).not_to be_nil
    # candidate_a and candidate_b are the same member (graph://member/1) -
    # deduped to 2 unique candidates, not 3.
    expect(CBGP::OrcidMiningJobs.status(job_id)[:total]).to eq(2)
    expect(estimated_seconds).to be > 0
  end

  it "never calls CBGP::Parsers.mine_member_orcid itself (that's the background job's work, not this method's)" do
    allow(CBGP::Loaders).to receive(:load_or_fetch_doi).and_return(
      { pub: double('pub'), existing: false,
        pending_orcid_candidates: [{ given: 'Ana', family: 'Ruiz', graph: 'graph://member/1', doi: '10.1/a' }] }
    )
    expect(CBGP::Parsers).not_to receive(:mine_member_orcid)

    CBGP::Loaders.bulk_load_from_dois(dois: '10.1/a')
  end
end
