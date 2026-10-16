# frozen_string_literal: true

# Covers a real incident (2026-10-15): a legacy stored value in
# member_research_area_group ("Lab Group 3/Legacy note: Phytopathogenic
# bacteria" - free text that slipped past an earlier load's
# controlled-vocabulary check) isn't shaped like a valid ontology id.
# get_label_for_id's validate_local_name! guard correctly rejects it with
# ArgumentError (that guard is a deliberate SPARQL-injection boundary and
# must stay strict), but cached_label_for_id let that exception escape
# uncaught - crashing the ENTIRE save transaction for any record containing
# such a value, instead of falling back to the raw value the way its own
# caller (resolve_display_value) already expected via `|| value.to_s`.
#
# Exercised against the real fixture ontology, not a mock of
# get_label_for_id: it's a bare top-level method (defined outside any
# class/module), and stubbing it via `allow(Object).to receive(...)` turns
# out not to intercept the call cached_label_for_id actually makes -
# confirmed live, the "mocked" version of this spec passed on two out of
# three examples purely by coincidence (the real unmocked behavior happened
# to match), which is worse than no test at all. Same real-fixture approach
# spec/lib/dataset_classes_currency_spec.rb already uses.
RSpec.describe 'cached_label_for_id' do
  before do
    # LABEL_LOOKUP_CACHE is a shared module-level cache - clear it so one
    # example's result can't leak into another via a shared key.
    stub_const('LABEL_LOOKUP_CACHE', {})
  end

  it 'falls back to nil instead of raising when the stored value is not a valid-looking id' do
    result = nil
    expect do
      result = cached_label_for_id(id: 'Lab Group 3/Legacy note: Phytopathogenic bacteria', language: 'en')
    end.not_to raise_error
    expect(result).to be_nil
  end

  it 'returns nil, not an exception, for a validly-shaped id that just has no real answer (not the crash case)' do
    expect { cached_label_for_id(id: 'definitely_not_a_real_answer_id_xyz', language: 'en') }.not_to raise_error
  end

  it 'still returns a real label for a genuinely valid id' do
    field = CBGP::Dataset.fields_for('member').find { |f| f[:questionclass] == 'member_nationality' }
    raise "fixture ontology no longer has 'member_nationality' - update this spec" unless field

    label = cached_label_for_id(id: 'spain', language: 'en')
    expect(label).to be_a(String)
    expect(label).not_to be_empty
  end
end
