# frozen_string_literal: true

# Covers the generic safety net added to write_dataset_to_db_query after a
# real incident (2026-10-15): a caller read an existing record incompletely
# (via a graph URI pointing at the wrong RDF namespace) and wrote back only
# the one field it meant to change, silently destroying every other field
# on 704 real member records. The write itself never raised anything - it
# "succeeded" cleanly every single time. This is the pure decision logic
# that now blocks any future write shaped like that, for every form type,
# not just member - see write_dataset_to_db_query for where it's wired in.
RSpec.describe 'looks_like_silent_data_loss?' do
  it 'flags the exact shape of the real incident: a well-populated record collapsing to one field' do
    expect(looks_like_silent_data_loss?(old_field_count: 15, new_field_count: 1)).to be(true)
  end

  it 'flags a well-populated record collapsing to zero fields too' do
    expect(looks_like_silent_data_loss?(old_field_count: 20, new_field_count: 0)).to be(true)
  end

  it 'does not flag a normal edit that keeps most fields intact' do
    expect(looks_like_silent_data_loss?(old_field_count: 15, new_field_count: 12)).to be(false)
  end

  it 'does not flag a record that only ever had a few fields to begin with' do
    expect(looks_like_silent_data_loss?(old_field_count: 2, new_field_count: 1)).to be(false)
  end

  it 'does not flag a brand-new record with no prior state at all' do
    expect(looks_like_silent_data_loss?(old_field_count: 0, new_field_count: 1)).to be(false)
  end

  it 'does not flag an edit that deliberately trims down to a still-substantial 2 fields' do
    expect(looks_like_silent_data_loss?(old_field_count: 15, new_field_count: 2)).to be(false)
  end
end
