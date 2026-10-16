# frozen_string_literal: true

# Covers CBGP::Dataset.load_from_graph's guard against a real incident
# (2026-10-15): a caller passed a subject URI (.../member/dataset/<id>)
# where the actual named graph (.../member/context/<id>) was required.
# fetch_datasets_raw_data silently found nothing for that wrong URI,
# load_from_graph returned a validly-shaped but empty Dataset, and the
# caller then wrote that empty object straight back to the database as a
# REPLACEMENT for the real record - destroying every field but one on 704
# real member records, with no error raised anywhere in the process. This
# must fail loudly instead.
RSpec.describe 'CBGP::Dataset.load_from_graph' do
  let(:real_details) do
    { dataset: 'http://admin.cbgp.upm.es/graphs/datasets/member/context/real-id',
      member_name: 'Jane', member_surnames: 'Doe García' }
  end

  it 'aborts rather than returning an empty-looking Dataset when the graph yields no field data' do
    allow(CBGP::Dataset).to receive(:fetch_datasets_raw_data)
      .and_return([{ dataset: 'http://admin.cbgp.upm.es/graphs/datasets/member/dataset/wrong-uri' }])

    expect do
      CBGP::Dataset.load_from_graph(graph: 'http://admin.cbgp.upm.es/graphs/datasets/member/dataset/wrong-uri',
                                     database: 'member', pre_fetched_primary_id: 'wrong-uri')
    end.to raise_error(SystemExit)
  end

  it 'aborts the same way when fetch_datasets_raw_data returns nothing at all for the graph' do
    allow(CBGP::Dataset).to receive(:fetch_datasets_raw_data).and_return([])

    expect do
      CBGP::Dataset.load_from_graph(graph: 'http://admin.cbgp.upm.es/graphs/datasets/member/context/missing',
                                     database: 'member', pre_fetched_primary_id: 'missing')
    end.to raise_error(SystemExit)
  end

  it 'loads normally when the graph genuinely holds field data' do
    allow(CBGP::Dataset).to receive(:fetch_datasets_raw_data).and_return([real_details])

    dataset = CBGP::Dataset.load_from_graph(
      graph: 'http://admin.cbgp.upm.es/graphs/datasets/member/context/real-id',
      database: 'member', pre_fetched_primary_id: 'real-id'
    )

    expect(dataset.primary_id).to eq('real-id')
    expect(dataset.name).to eq('Jane')
    expect(dataset.surname).to eq('Doe García')
  end
end
