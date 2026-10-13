# frozen_string_literal: true

# The shared records layer (lib/mcp/records.rb): how a model's search
# conditions become search-engine parameters, how fixed-list values and form
# names are resolved, how records are labelled. The ontology is stubbed at the
# Context seam, so these run without it and prove the rules are generic (no
# form or field is named anywhere in the layer).
RSpec.describe Mcp::Records::Context do
  FIELDS = [
    { questionclass: 'item_name', label: 'Name', class: 'string', cardinality: 'Single', answers: '', widget: 'text' },
    { questionclass: 'item_code', label: 'Code', class: 'string', cardinality: 'Single', answers: '', widget: 'text' },
    { questionclass: 'item_kind', label: 'Kind', class: 'string', cardinality: 'Single', widget: 'select',
      answers: 'https://example.org#kinds' },
    { questionclass: 'item_start', label: 'Start date', class: 'date', cardinality: 'Single', answers: '', widget: 'date' },
    { questionclass: 'item_end', label: 'End date', class: 'date', cardinality: 'Single', answers: '', widget: 'date' },
    { questionclass: 'item_owner', label: 'Owner', class: 'string', cardinality: 'Single', answers: '', widget: 'typeahead',
      references_target: 'person', references_via: 'https://example.org#person_key', references_label: 'person_name' }
  ].freeze
  KINDS = [{ id: 'kind_a', label: 'Alpha' }, { id: 'kind_b', label: 'Beta' },
           { id: 'dup_1', label: 'Twin', group: 'North' }, { id: 'dup_2', label: 'Twin', group: 'South' }].freeze

  let(:ctx) { described_class.new }
  let(:form) { Mcp::Records::FormInfo.new(name: 'item', storage: 'item', label: 'Item') }

  before do
    allow(ctx).to receive(:fields).and_return(FIELDS)
    allow(ctx).to receive(:vocabulary) { |field| field[:questionclass] == 'item_kind' ? KINDS : [] }
  end

  describe '#search_params' do
    def params_for(*conditions)
      ctx.search_params(form, conditions)
    end

    it 'is empty for no conditions' do
      expect(ctx.search_params(form, nil)).to eq({})
      expect(ctx.search_params(form, [])).to eq({})
    end

    it 'defaults to a text-contains match' do
      expect(params_for({ 'field' => 'item_name', 'value' => ' maria ' })).to eq('item_name' => 'maria')
    end

    it 'maps equals to an exact match and the not ops to a negation' do
      expect(params_for({ 'field' => 'item_code', 'op' => 'equals', 'value' => 'X1' })).to eq('item_code' => 'X1', 'item_code__exact' => '1')
      expect(params_for({ 'field' => 'item_code', 'op' => 'not_contains', 'value' => 'X' })).to eq('item_code' => 'X', 'item_code__not' => '1')
      expect(params_for({ 'field' => 'item_code', 'op' => 'not_equals', 'value' => 'X' }))
        .to eq('item_code' => 'X', 'item_code__exact' => '1', 'item_code__not' => '1')
    end

    it 'accepts the field by label or in another case' do
      expect(params_for({ 'field' => 'Name', 'value' => 'a' }).keys).to eq(['item_name'])
      expect(params_for({ 'field' => 'ITEM_CODE', 'value' => 'a' }).keys).to eq(['item_code'])
    end

    it 'turns date ops into a start/end range and passes today through' do
      expect(params_for({ 'field' => 'item_start', 'op' => 'between', 'start' => '2020-01-01', 'end' => '2020-12-31' }))
        .to eq('item_start' => { 'start' => '2020-01-01', 'end' => '2020-12-31' })
      expect(params_for({ 'field' => 'item_end', 'op' => 'on_or_after', 'value' => 'today' })).to eq('item_end' => { 'start' => 'today' })
      expect(params_for({ 'field' => 'item_end', 'op' => 'on_or_before', 'value' => '2021-01-01' })).to eq('item_end' => { 'end' => '2021-01-01' })
    end

    it 'adds the or-empty flag only when asked' do
      expect(params_for({ 'field' => 'item_end', 'op' => 'on_or_after', 'value' => 'today', 'or_empty' => true }))
        .to include('item_end__orempty' => '1')
      expect(params_for({ 'field' => 'item_end', 'op' => 'on_or_after', 'value' => 'today' })).not_to include('item_end__orempty')
    end

    it 'resolves a fixed-list label to its id' do
      expect(params_for({ 'field' => 'item_kind', 'value' => 'alpha' })).to eq('item_kind' => 'kind_a')
      expect(params_for({ 'field' => 'item_kind', 'op' => 'equals', 'value' => 'kind_b' })).to include('item_kind' => 'kind_b')
    end

    it 'refuses an invalid fixed-list value, listing what is allowed' do
      expect { params_for({ 'field' => 'item_kind', 'value' => 'gamma' }) }
        .to raise_error(Mcp::ToolError, /not a valid value for item_kind.*kind_a = Alpha.*kind_b = Beta/)
    end

    it 'refuses a label shared by two values, listing their ids and groups' do
      expect { params_for({ 'field' => 'item_kind', 'value' => 'twin' }) }
        .to raise_error(Mcp::ToolError, /dup_1 \(North\).*dup_2 \(South\)/)
    end

    describe 'refuses what cannot work, saying what would' do
      it('unknown field') { expect { params_for({ 'field' => 'nope', 'value' => 'x' }) }.to raise_error(Mcp::ToolError, /no field 'nope'.*item_name, item_code/) }
      it('unknown op') { expect { params_for({ 'field' => 'item_name', 'op' => 'like', 'value' => 'x' }) }.to raise_error(Mcp::ToolError, /Unknown op 'like'.*contains/) }
      it('date op on a text field') { expect { params_for({ 'field' => 'item_name', 'op' => 'between', 'start' => '2020-01-01' }) }.to raise_error(Mcp::ToolError, /needs a date field/) }
      it('text op on a date field') { expect { params_for({ 'field' => 'item_start', 'value' => '2020' }) }.to raise_error(Mcp::ToolError, /is a date; use op between/) }
      it('bad date') { expect { params_for({ 'field' => 'item_start', 'op' => 'on_or_after', 'value' => 'tomorrow' }) }.to raise_error(Mcp::ToolError, /not a valid date/) }
      it('no date at all') { expect { params_for({ 'field' => 'item_start', 'op' => 'between' }) }.to raise_error(Mcp::ToolError, /needs a date/) }
      it('missing value') { expect { params_for({ 'field' => 'item_name' }) }.to raise_error(Mcp::ToolError, /non-empty 'value'/) }
      it('two conditions on one field') { expect { params_for({ 'field' => 'item_name', 'value' => 'a' }, { 'field' => 'item_name', 'value' => 'b' }) }.to raise_error(Mcp::ToolError, /Only one condition per field/) }
      it('where not a list') { expect { ctx.search_params(form, 'x') }.to raise_error(Mcp::ToolError, /must be a list/) }
      it('a condition that is not an object') { expect { params_for('x') }.to raise_error(Mcp::ToolError, /must be an object/) }
    end
  end

  describe '#form!' do
    let(:forms) do
      [Mcp::Records::FormInfo.new(name: 'funding_commitment', storage: 'commitment', label: 'Funding Commitment'),
       Mcp::Records::FormInfo.new(name: 'member', storage: 'member', label: 'Member')]
    end

    before { allow(ctx).to receive(:forms).and_return(forms) }

    it 'accepts a form name, in any case, or its label' do
      expect(ctx.form!('member').name).to eq('member')
      expect(ctx.form!('MEMBER').name).to eq('member')
      expect(ctx.form!('funding commitment').name).to eq('funding_commitment')
    end

    it 'accepts a storage name' do
      expect(ctx.form!('commitment').storage).to eq('commitment')
    end

    it 'names the valid forms when the form is unknown or missing' do
      expect { ctx.form!('meber') }.to raise_error(Mcp::ToolError, /Valid forms: funding_commitment, member/)
      expect { ctx.form!('') }.to raise_error(Mcp::ToolError, /describe_form/)
    end
  end

  describe '#label_for' do
    it 'uses the declared label fields when the ontology declares them' do
      allow(ctx).to receive(:label_spec).with('item').and_return(%w[item_name item_code])
      expect(ctx.label_for('item', { item_name: 'Ana', item_code: 'Z9' })).to eq('Ana, Z9')
    end

    it 'skips declared label fields the record has no value for' do
      allow(ctx).to receive(:label_spec).with('item').and_return(%w[item_name item_code])
      expect(ctx.label_for('item', { item_name: 'Ana' })).to eq('Ana')
    end

    it 'falls back to the first two descriptive values, never dates, with fixed-list ids shown as labels' do
      allow(ctx).to receive(:label_spec).and_return(nil)
      allow(ctx).to receive(:vocabulary_label) { |_f, id| id == 'kind_a' ? 'Alpha' : nil }
      raw = { item_name: 'Ana', item_kind: 'kind_a', item_start: '2020-01-01', item_code: 'Z9' }
      expect(ctx.label_for('item', raw)).to eq('Ana - Z9')
    end
  end

  describe '#serialize (via build_records)' do
    it 'puts date fields only under dates, omits blanks, and labels fixed-list values' do
      allow(ctx).to receive(:label_spec).and_return(%w[item_name])
      allow(ctx).to receive(:vocabulary_label) { |_f, id| id == 'kind_a' ? 'Alpha' : nil }
      raw = { dataset: "#{BASE_URI}item/context/abc", item_name: 'Ana', item_kind: 'kind_a', item_start: '2020-01-01', item_end: '', item_code: [] }
      allow(ctx).to receive(:raw_records_for).and_return([raw])
      allow(ctx).to receive(:record_stamps).and_return("#{BASE_URI}item/context/abc" => 'item_special')

      record = ctx.build_records(form, ["#{BASE_URI}item/context/abc"]).first
      expect(record).to eq(form: 'item_special', id: 'abc', label: 'Ana',
                           dates: { 'item_start' => '2020-01-01' }, fields: { 'item_name' => 'Ana', 'item_kind' => 'kind_a' },
                           value_labels: { 'item_kind' => 'Alpha' })
    end
  end

  describe '#inbound_references' do
    it 'finds each cross-reference field that points at a storage once, even when forms share it' do
      other = [{ questionclass: 'link_to_item', label: 'Item', class: 'string', cardinality: 'Single', answers: '',
                 references_target: 'member', references_via: 'https://example.org#member_dni_nie_pas' }]
      one = Mcp::Records::FormInfo.new(name: 'a_form', storage: 'shared', label: 'A')
      two = Mcp::Records::FormInfo.new(name: 'b_form', storage: 'shared', label: 'B')
      allow(ctx).to receive(:forms).and_return([one, two])
      allow(ctx).to receive(:fields).and_return(other)
      found = ctx.inbound_references('member')
      expect(found.size).to eq(1)
      expect(found.first[:field][:questionclass]).to eq('link_to_item')
    end
  end
end

RSpec.describe Mcp::Records::Context, 'with a graph that holds no record' do
  it 'leaves it out rather than returning an empty record' do
    ctx = described_class.new
    form = Mcp::Records::FormInfo.new(name: 'item', storage: 'item', label: 'Item')
    allow(ctx).to receive(:fields).and_return([{ questionclass: 'item_name', label: 'Name', class: 'string', cardinality: 'Single', answers: '' }])
    allow(ctx).to receive(:raw_records_for).and_return([{ dataset: "#{BASE_URI}item/context/ghost" }])
    allow(ctx).to receive(:record_stamps).and_return({})
    expect(ctx.build_records(form, ["#{BASE_URI}item/context/ghost"])).to eq([])
  end
end

# A Spanish question reaches the tools with Spanish words, English labels, or a
# mixture: every path below must work (the suite otherwise runs in English).
RSpec.describe Mcp::Records::Context, 'in Spanish' do
  let(:ctx) { described_class.new }
  let(:form) { Mcp::Records::FormInfo.new(name: 'item', storage: 'item', label: 'Item') }
  let(:kind_field) { { questionclass: 'item_kind', label: 'Tipo', class: 'string', cardinality: 'Single', widget: 'select', answers: 'https://example.org#kinds' } }
  let(:date_field) { { questionclass: 'item_end', label: 'Fecha de fin', class: 'date', cardinality: 'Single', answers: '', widget: 'date' } }

  before do
    allow(ctx).to receive(:fields).and_return([kind_field, date_field])
    allow(ctx).to receive(:vocabulary) do |_field, language = current_language|
      language == 'es' ? [{ id: 'k_prof', label: 'Catedrático' }, { id: 'k_tec', label: 'Técnico' }] : [{ id: 'k_prof', label: 'Full professor' }, { id: 'k_tec', label: 'Technician' }]
    end
    Thread.current[:language] = 'es'
  end

  it 'matches a Spanish label, ignoring case and accents' do
    expect(ctx.search_params(form, [{ 'field' => 'item_kind', 'value' => 'catedratico' }])).to eq('item_kind' => 'k_prof')
  end

  it 'matches an English label even while the language is Spanish' do
    expect(ctx.search_params(form, [{ 'field' => 'item_kind', 'value' => 'Full professor' }])).to eq('item_kind' => 'k_prof')
  end

  it 'matches a Spanish label while the language is English' do
    Thread.current[:language] = 'en'
    expect(ctx.search_params(form, [{ 'field' => 'item_kind', 'value' => 'Técnico' }])).to eq('item_kind' => 'k_tec')
  end

  it 'lists the options in the current language when nothing matches' do
    expect { ctx.search_params(form, [{ 'field' => 'item_kind', 'value' => 'nada' }]) }
      .to raise_error(Mcp::ToolError, /k_prof = Catedrático/)
  end

  it 'accepts hoy (and any case of it) as today, and still refuses other words' do
    expect(ctx.search_params(form, [{ 'field' => 'item_end', 'op' => 'on_or_after', 'value' => 'hoy' }])).to eq('item_end' => { 'start' => 'today' })
    expect(ctx.search_params(form, [{ 'field' => 'item_end', 'op' => 'on_or_before', 'value' => 'HOY' }])).to eq('item_end' => { 'end' => 'today' })
    expect { ctx.search_params(form, [{ 'field' => 'item_end', 'op' => 'on_or_after', 'value' => 'mañana' }]) }
      .to raise_error(Mcp::ToolError, /not a valid date/)
  end

  it 'accepts the Spanish word for a field label' do
    expect(ctx.search_params(form, [{ 'field' => 'Tipo', 'value' => 'Técnico' }]).keys).to eq(['item_kind'])
  end
end

# What depends only on the ontology is worked out once per process, not once per call (it cost seconds
# per call before), and is dropped when the ontology is replaced.
RSpec.describe Mcp::Records::Shared do
  it 'works an answer out once, however many calls ask for it' do
    runs = 0
    2.times { expect(described_class.fetch(:thing, 'x') { runs += 1; 'answer' }).to eq('answer') }
    expect(runs).to eq(1)
  end

  it 'keeps different keys apart' do
    expect(described_class.fetch(:a) { 1 }).to eq(1)
    expect(described_class.fetch(:b) { 2 }).to eq(2)
  end

  it 'forgets everything when a different ontology is loaded' do
    described_class.fetch(:thing) { 'old' }
    original = $ontology
    begin
      $ontology = Object.new
      expect(described_class.fetch(:thing) { 'new' }).to eq('new')
    ensure
      $ontology = original
    end
  end

  it 'lets a new Context reuse the fields an earlier one found' do
    calls = 0
    allow(CBGP::Dataset).to receive(:fields_for) { calls += 1; [] }
    2.times { Mcp::Records::Context.new.fields('anything') }
    expect(calls).to eq(1)
  end
end

RSpec.describe Mcp::Records, '.warm_up' do
  it 'never raises, so a start-up problem cannot stop the server' do
    allow_any_instance_of(Mcp::Records::Context).to receive(:forms).and_raise(StandardError, 'no store')
    expect { described_class.warm_up }.to output(/warm-up skipped: StandardError: no store/).to_stderr
  end

  it 'leaves the calling thread language as it found it' do
    allow_any_instance_of(Mcp::Records::Context).to receive(:forms).and_return([])
    Thread.current[:language] = 'es'
    expect { described_class.warm_up }.to output(/warm-up done/).to_stderr
    expect(Thread.current[:language]).to eq('es')
  end
end
