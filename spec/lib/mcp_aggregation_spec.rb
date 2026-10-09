# frozen_string_literal: true

# Counting and adding up (lib/mcp/aggregation.rb). The arithmetic is exercised on plain data: nothing here
# needs the ontology or the databases, and nothing names a particular form or field.
RSpec.describe Mcp::Aggregation do
  let(:today) { Date.new(2026, 10, 9) }

  def spec(**opts)
    described_class::Spec.new(**{ measure: 'count', value_fields: [], group_fields: [] }.merge(opts))
  end

  def rec(form = nil, **values)
    { form: form, values: values.transform_keys(&:to_s).transform_values { |v| Array(v) } }
  end

  def cells(records, **opts)
    described_class.compute(records: records, spec: spec(**opts), today: today)[:cells]
  end

  describe 'counting and grouping' do
    it 'counts all records when nothing else is asked' do
      expect(cells([rec, rec, rec])).to eq([nil] => 3)
    end

    it 'counts by a category, with "(none)" for records that have no value' do
      out = cells([rec(g: 'f'), rec(g: 'f'), rec(g: 'm'), rec, rec(g: '')], group_fields: ['g'])
      expect(out).to eq([nil, 'f'] => 2, [nil, 'm'] => 1, [nil, '(none)'] => 2)
    end

    it 'puts a record with several values in each of their groups' do
      expect(cells([rec(tag: %w[a b]), rec(tag: 'a')], group_fields: ['tag'])).to eq([nil, 'a'] => 2, [nil, 'b'] => 1)
    end

    it 'counts a repeated value once per record' do
      expect(cells([rec(tag: %w[a a])], group_fields: ['tag'])).to eq([nil, 'a'] => 1)
    end

    it 'splits by two categories' do
      out = cells([rec(g: 'f', c: 'x'), rec(g: 'f', c: 'y'), rec(g: 'm', c: 'x')], group_fields: %w[g c])
      expect(out).to eq([nil, 'f', 'x'] => 1, [nil, 'f', 'y'] => 1, [nil, 'm', 'x'] => 1)
    end

    it 'can split by the form that wrote each record' do
      out = cells([rec('european'), rec('european'), rec('private')], group_fields: [described_class::RECORD_FORM])
      expect(out).to eq([nil, 'european'] => 2, [nil, 'private'] => 1)
    end
  end

  describe 'sums and averages' do
    it 'adds up a number field, ignoring records without one and saying so' do
      result = described_class.compute(records: [rec(amount: '100.50'), rec(amount: '200'), rec], spec: spec(measure: 'sum', value_fields: ['amount']), today: today)
      expect(result[:cells]).to eq([nil] => BigDecimal('300.5'))
      expect(result[:excluded]).to eq('no amount' => 1)
    end

    it 'uses the first of several fields that a record has a value for' do
      out = cells([rec(a: '10'), rec(b: '5'), rec(a: '', b: '7'), rec(a: '1', b: '99')], measure: 'sum', value_fields: %w[a b])
      expect(out).to eq([nil] => BigDecimal('23'))
    end

    it 'skips a value that is not a number' do
      result = described_class.compute(records: [rec(amount: 'n/a'), rec(amount: '4')], spec: spec(measure: 'sum', value_fields: ['amount']), today: today)
      expect(result[:cells]).to eq([nil] => BigDecimal('4'))
      expect(result[:excluded].values.sum).to eq(1)
    end

    it 'averages per group' do
      out = cells([rec(g: 'x', n: '2'), rec(g: 'x', n: '4'), rec(g: 'y', n: '10')], measure: 'avg', value_fields: ['n'], group_fields: ['g'])
      expect(out).to eq([nil, 'x'] => BigDecimal('3'), [nil, 'y'] => BigDecimal('10'))
    end
  end

  describe 'by_date: a record counts in the year of a date' do
    let(:by_date) { { mode: 'by_date', date_field: 'when' } }

    it 'buckets by year' do
      out = cells([rec(when: '2024-03-01'), rec(when: '2024-12-31'), rec(when: '2025-01-01')], **by_date)
      expect(out).to eq([2024] => 2, [2025] => 1)
    end

    it 'leaves out, and reports, records with no or an invalid date' do
      result = described_class.compute(records: [rec(when: '2024-01-01'), rec, rec(when: 'soon')], spec: spec(**by_date), today: today)
      expect(result[:cells]).to eq([2024] => 1)
      expect(result[:excluded]).to eq('no when' => 2)
    end

    it 'honours from and to' do
      records = %w[2022-01-01 2023-06-01 2024-06-01 2025-06-01].map { |d| rec(when: d) }
      expect(cells(records, **by_date, from: 2023, to: 2024)).to eq([2023] => 1, [2024] => 1)
    end

    it 'adds up amounts per year and category' do
      out = cells([rec(when: '2024-02-02', g: 'x', n: '10'), rec(when: '2024-09-09', g: 'x', n: '5'), rec(when: '2025-01-01', g: 'y', n: '1')],
                  **by_date, measure: 'sum', value_fields: ['n'], group_fields: ['g'])
      expect(out).to eq([2024, 'x'] => BigDecimal('15'), [2025, 'y'] => BigDecimal('1'))
    end

    it 'reads a full timestamp as its date' do
      expect(cells([rec(when: '2024-05-05T10:00:00Z')], **by_date)).to eq([2024] => 1)
    end
  end

  describe 'active_at_end: a headcount at the end of each year' do
    let(:mode) { { mode: 'active_at_end', start_field: 's', end_field: 'e' } }

    it 'counts a person in each year they are on at the end of it' do
      out = cells([rec(s: '2019-03-01', e: '2021-06-30')], **mode)
      expect(out).to eq([2019] => 1, [2020] => 1) # gone by 31 December 2021
    end

    it 'counts someone who leaves exactly on 31 December in that year' do
      expect(cells([rec(s: '2020-01-01', e: '2020-12-31')], **mode)).to eq([2020] => 1)
    end

    it 'counts a person with no end date as still here, up to today, and not in future years' do
      out = cells([rec(s: '2025-01-01')], **mode)
      expect(out).to eq([2025] => 1, [2026] => 1)
    end

    it 'counts the current year as of today, not 31 December' do
      leaves_soon = rec(s: '2020-01-01', e: '2026-10-01') # left before today
      still_here = rec(s: '2020-01-01', e: '2026-12-31')
      out = cells([leaves_soon, still_here], **mode)
      expect(out[[2026]]).to eq(1)
      expect(out[[2025]]).to eq(2)
    end

    it 'does not run into future years for someone whose end date is ahead' do
      expect(cells([rec(s: '2026-01-01', e: '2030-01-01')], **mode).keys).to eq([[2026]])
    end

    it 'splits a headcount by category and year' do
      out = cells([rec(s: '2020-01-01', g: 'f'), rec(s: '2020-06-01', g: 'm'), rec(s: '2021-02-01', g: 'f')], **mode, group_fields: ['g'])
      expect(out[[2020, 'f']]).to eq(1)
      expect(out[[2020, 'm']]).to eq(1)
      expect(out[[2021, 'f']]).to eq(2)
    end

    it 'leaves out, and reports, people with no start date or an end before the start' do
      result = described_class.compute(records: [rec(e: '2020-01-01'), rec(s: '2021-01-01', e: '2020-01-01'), rec(s: '2020-01-01', e: '2020-12-31')], spec: spec(**mode), today: today)
      expect(result[:cells]).to eq([2020] => 1)
      expect(result[:excluded]).to eq('no s' => 1, 'e before s' => 1)
    end

    it 'works with a start date only' do
      out = cells([rec(s: '2024-05-05')], mode: 'active_at_end', start_field: 's')
      expect(out.keys).to eq([[2024], [2025], [2026]])
    end

    it 'honours from and to' do
      out = cells([rec(s: '2019-01-01')], **mode, from: 2024, to: 2025)
      expect(out.keys).to eq([[2024], [2025]])
    end
  end

  describe 'active_during: present at any point in the year' do
    let(:mode) { { mode: 'active_during', start_field: 's', end_field: 'e' } }

    it 'counts a stay in every year it touches, even for a day' do
      expect(cells([rec(s: '2019-12-31', e: '2020-01-01')], **mode)).to eq([2019] => 1, [2020] => 1)
    end

    it 'does not count the years after someone left' do
      expect(cells([rec(s: '2020-03-01', e: '2020-04-01')], **mode)).to eq([2020] => 1)
    end
  end

  describe 'spread: an amount shared across the years a record runs' do
    let(:mode) { { mode: 'spread', start_field: 's', end_field: 'e', measure: 'sum', value_fields: ['n'] } }

    it 'shares an amount in proportion to the days in each year, and adds back up to the total' do
      out = cells([rec(s: '2024-07-01', e: '2025-06-30', n: '1000')], **mode)
      expect(out.keys).to eq([[2024], [2025]])
      expect(out[[2024]].round(2)).to eq(BigDecimal('504.11')) # 184 of 365 days
      expect(out[[2025]].round(2)).to eq(BigDecimal('495.89')) # 181 of 365 days
      expect(out.values.sum.round(2)).to eq(BigDecimal('1000'))
    end

    it 'puts a record inside one year entirely in that year' do
      expect(cells([rec(s: '2024-02-01', e: '2024-03-01', n: '50')], **mode)).to eq([2024] => BigDecimal('50'))
    end

    it 'spreads over many years, including years ahead, and still adds up' do
      out = cells([rec(s: '2025-01-01', e: '2029-12-31', n: '5000')], **mode)
      expect(out.keys.map(&:first)).to eq((2025..2029).to_a)
      expect(out.values.sum.round(2)).to eq(BigDecimal('5000'))
    end

    it 'adds up several records by category and year' do
      out = cells([rec(s: '2024-01-01', e: '2024-12-31', n: '100', g: 'x'), rec(s: '2024-01-01', e: '2025-12-31', n: '200', g: 'x'), rec(s: '2025-01-01', e: '2025-12-31', n: '10', g: 'y')],
                  **mode, group_fields: ['g'])
      expect(out[[2024, 'x']].round(2)).to eq(BigDecimal('200.14')) # all of the first (100) + 366 of the second's 731 days (100.14)
      expect(out[[2025, 'x']].round(2)).to eq(BigDecimal('99.86'))
      expect(out[[2025, 'y']]).to eq(BigDecimal('10'))
    end

    it 'leaves out, and reports, records with no end date (their total cannot be shared)' do
      result = described_class.compute(records: [rec(s: '2024-01-01', n: '100'), rec(s: '2024-01-01', e: '2024-12-31', n: '10')], spec: spec(**mode), today: today)
      expect(result[:cells]).to eq([2024] => BigDecimal('10'))
      expect(result[:excluded]).to eq('no e' => 1)
    end

    it 'counts a one-day record' do
      expect(cells([rec(s: '2024-05-05', e: '2024-05-05', n: '7')], **mode)).to eq([2024] => BigDecimal('7'))
    end
  end
end

RSpec.describe Mcp::Aggregation, 'checking the request' do
  let(:ctx) { Mcp::Records::Context.new }
  let(:form) { Mcp::Records::FormInfo.new(name: 'thing', storage: 'thing', label: 'Thing') }
  let(:fields) do
    [{ questionclass: 'when', label: 'When', class: 'date', cardinality: 'Single', answers: '' },
     { questionclass: 'amount', label: 'Amount', class: 'currency', cardinality: 'Single', answers: '' },
     { questionclass: 'pct', label: 'Percent', class: 'number', cardinality: 'Single', answers: '' },
     { questionclass: 'kind', label: 'Kind', class: 'string', cardinality: 'Single', answers: '' },
     { questionclass: 'side', label: 'Side', class: 'string', cardinality: 'Single', answers: '' }]
  end

  before { allow(ctx).to receive(:fields).and_return(fields) }

  def spec_for(**opts)
    described_class.build_spec(ctx, form, opts[:measure], opts[:field], opts[:group_by], opts[:over_time], opts[:from], opts[:to])
  end

  it 'accepts a plain count, a sum of number fields, and the record_form category' do
    expect(spec_for.measure).to eq('count')
    expect(spec_for(measure: 'sum', field: %w[amount pct]).value_fields).to eq(%w[amount pct])
    expect(spec_for(group_by: %w[RECORD_FORM kind]).group_fields).to eq(%w[record_form kind])
  end

  it 'takes a field by its label' do
    expect(spec_for(measure: 'sum', field: ['Amount']).value_fields).to eq(['amount'])
  end

  describe 'refuses what cannot work, saying what would' do
    it('an unknown measure') { expect { spec_for(measure: 'median') }.to raise_error(Mcp::ToolError, /measure must be one of: count, sum, avg/) }
    it('a sum with no field') { expect { spec_for(measure: 'sum') }.to raise_error(Mcp::ToolError, /needs field/) }
    it('a sum of text') { expect { spec_for(measure: 'sum', field: ['kind']) }.to raise_error(Mcp::ToolError, /needs a number or currency field/) }
    it('an unknown field') { expect { spec_for(group_by: ['nope']) }.to raise_error(Mcp::ToolError, /no field 'nope'/) }
    it('three groups') { expect { spec_for(group_by: %w[kind side when]) }.to raise_error(Mcp::ToolError, /at most two/) }
    it('an unknown mode') { expect { spec_for(over_time: { 'mode' => 'weekly' }) }.to raise_error(Mcp::ToolError, /mode must be one of/) }
    it('a mode with its date missing') { expect { spec_for(over_time: { 'mode' => 'by_date' }) }.to raise_error(Mcp::ToolError, /date_field is required/) }
    it('a date field that is not a date') { expect { spec_for(over_time: { 'mode' => 'by_date', 'date_field' => 'kind' }) }.to raise_error(Mcp::ToolError, /not a date/) }
    it('spread with count') { expect { spec_for(over_time: { 'mode' => 'spread', 'start_field' => 'when', 'end_field' => 'when' }) }.to raise_error(Mcp::ToolError, /spread needs measure sum/) }
    it('spread with no end field') { expect { spec_for(measure: 'sum', field: ['amount'], over_time: { 'mode' => 'spread', 'start_field' => 'when' }) }.to raise_error(Mcp::ToolError, /end_field is required/) }
    it('a finer granularity than year') { expect { spec_for(over_time: { 'mode' => 'by_date', 'date_field' => 'when', 'granularity' => 'month' }) }.to raise_error(Mcp::ToolError, /year/) }
    it('over_time that is not an object') { expect { spec_for(over_time: 'yearly') }.to raise_error(Mcp::ToolError, /must be an object/) }
    it('a year that is not a year') { expect { spec_for(from: 'soon') }.to raise_error(Mcp::ToolError, /from must be a year/) }
  end

  it 'asks only for the fields it needs' do
    spec = spec_for(measure: 'sum', field: ['amount'], group_by: %w[kind record_form], over_time: { 'mode' => 'spread', 'start_field' => 'when', 'end_field' => 'when' })
    expect(described_class.spec_fields(spec)).to contain_exactly('when', 'amount', 'kind')
  end
end

RSpec.describe Mcp::Aggregation, 'presenting the answer' do
  let(:ctx) { Mcp::Records::Context.new }
  let(:form) { Mcp::Records::FormInfo.new(name: 'thing', storage: 'thing', label: 'Thing') }
  let(:today) { Date.new(2026, 10, 9) }

  before do
    allow(ctx).to receive(:fields).and_return([{ questionclass: 'g', label: 'G', class: 'string', cardinality: 'Single', answers: '' }])
    allow(ctx).to receive(:vocabulary_label) { |_f, id| { 'f' => 'Female', 'm' => 'Male' }[id] }
    allow(ctx).to receive(:all_forms).and_return([Mcp::Records::FormInfo.new(name: 'european', storage: 'project', label: 'European projects')])
  end

  def decorate(records, **opts)
    spec = described_class::Spec.new(**{ measure: 'count', value_fields: [], group_fields: [] }.merge(opts))
    result = described_class.compute(records: records, spec: spec, today: today)
    described_class.decorate(ctx, form, spec, result, today)
  end

  it 'gives tidy rows with the period, the group, its readable label and the value, sorted' do
    out = decorate([{ form: nil, values: { 'g' => ['m'], 's' => ['2020-01-01'] } }, { form: nil, values: { 'g' => ['f'], 's' => ['2021-01-01'] } }],
                   group_fields: ['g'], mode: 'active_at_end', start_field: 's')
    expect(out[:rows].first).to eq(period: '2020', group: 'm', label: 'Male', value: 1)
    expect(out[:rows].map { |r| [r[:period], r[:group]] }).to eq(out[:rows].map { |r| [r[:period], r[:group]] }.sort) # sorted
    expect(out[:rows].map { |r| r[:period] }.uniq).to eq((2020..2026).map(&:to_s)) # a headcount runs on to the current year
    expect(out[:rows].count { |r| r[:period] == '2021' }).to eq(2) # one man, one woman by the end of 2021
    expect(out).to include(measure: 'count', by: ['g'], records_considered: 2, as_of: '2026-10-09')
  end

  it 'labels the form that wrote a record with the form\'s own name' do
    out = decorate([{ form: 'european', values: {} }], group_fields: [described_class::RECORD_FORM])
    expect(out[:rows]).to eq([{ group: 'european', label: 'European projects', value: 1 }])
  end

  it 'reports what was left out and explains how the current year is counted' do
    out = decorate([{ form: nil, values: {} }], mode: 'active_at_end', start_field: 's')
    expect(out[:excluded]).to eq('no s' => 1)
    expect(out[:notes].join(' ')).to include('current year (2026)', 'excluded')
  end

  it 'shows counts as whole numbers and sums with two decimals' do
    counted = decorate([{ form: nil, values: {} }])
    expect(counted[:rows].first[:value]).to be_a(Integer)
    summed = decorate([{ form: nil, values: { 'n' => ['10.456'] } }], measure: 'sum', value_fields: ['n'])
    expect(summed[:rows].first[:value]).to eq(10.46)
  end

  it 'caps a huge answer and says so' do
    records = Array.new(700) { |i| { form: nil, values: { 'g' => ["group#{i}"] } } }
    out = decorate(records, group_fields: ['g'])
    expect(out[:rows].size).to eq(described_class::MAX_ROWS)
    expect(out[:notes].join).to include('More than 600 rows')
  end

  it 'describes a sum by the fields it used' do
    out = decorate([], measure: 'sum', value_fields: %w[a b])
    expect(out[:measure]).to eq('sum of a or b')
  end
end

RSpec.describe Mcp::Aggregation::Source do
  let(:ctx) { Mcp::Records::Context.new }
  let(:form) { Mcp::Records::FormInfo.new(name: 'thing', storage: 'thing', label: 'Thing') }
  let(:row_class) do
    Struct.new(:data) do
      def [](key) = data[key]
      def bound?(key) = data.key?(key)
    end
  end

  before do
    allow(ctx).to receive(:fields).and_return([{ questionclass: 'one', cardinality: 'Single' }, { questionclass: 'two', cardinality: 'Single' },
                                               { questionclass: 'many', cardinality: 'Multiple' }])
  end

  def row(graph, **vals)
    row_class.new({ graph: graph }.merge(vals))
  end

  it 'reads single-valued fields in one query and each many-valued field in its own' do
    queries = []
    allow(DATABASE).to receive(:query) { |q| queries << q; [] }
    described_class.fetch(ctx: ctx, form: form, graphs: ['urn:g1'], fields: %w[one two many])
    expect(queries.size).to eq(2)
    expect(queries[0]).to include('?one', '?two')
    expect(queries[0]).not_to include('?many')
    expect(queries[1]).to include('?many')
  end

  it 'gathers values per record, with each distinct value once' do
    allow(DATABASE).to receive(:query).and_return(
      [row('urn:g1', one: RDF::Literal('a'), two: RDF::Literal('b')), row('urn:g2', one: RDF::Literal('c'))]
    )
    out = described_class.fetch(ctx: ctx, form: form, graphs: %w[urn:g1 urn:g2], fields: %w[one two])
    expect(out.map { |r| r[:values] }).to eq([{ 'one' => ['a'], 'two' => ['b'] }, { 'one' => ['c'] }])
  end

  it 'adds the form that wrote each record when asked' do
    allow(DATABASE).to receive(:query).and_return([row('urn:g1', one: RDF::Literal('a'))])
    allow(described_class).to receive(:stamps).and_return('urn:g1' => 'european')
    expect(described_class.fetch(ctx: ctx, form: form, graphs: ['urn:g1'], fields: ['one'], with_form: true).first[:form]).to eq('european')
  end

  it 'reads in chunks so a big form cannot make one enormous query' do
    stub_const("#{described_class}::CHUNK", 2)
    seen = []
    allow(DATABASE).to receive(:query) { |q| seen << q.scan('<urn:g').size; [] }
    described_class.fetch(ctx: ctx, form: form, graphs: %w[urn:g1 urn:g2 urn:g3], fields: ['one'])
    expect(seen).to eq([2, 1])
  end

  it 'returns nothing for no records, without asking the database' do
    expect(DATABASE).not_to receive(:query)
    expect(described_class.fetch(ctx: ctx, form: form, graphs: [], fields: ['one'])).to eq([])
  end

  it 'refuses a field name that is not a plain identifier, so it cannot reach the query' do
    expect { described_class.read(['urn:g1'], ['one } DROP ALL #'], {}) }.to raise_error(ArgumentError)
  end
end

RSpec.describe Mcp::Tools::Aggregate do
  it 'passes the request on and returns the engine\'s answer' do
    allow(Mcp::Records::Context).to receive(:new).and_wrap_original do |original|
      original.call.tap { |c| allow(c).to receive(:form!).and_return(Mcp::Records::FormInfo.new(name: 'member', storage: 'member', label: 'Member')) }
    end
    expect(Mcp::Aggregation).to receive(:run).with(hash_including(group_by: ['member_gender'], from: '2020')).and_return(rows: [{ value: 3 }])
    body = JSON.parse(described_class.invoke('form' => 'member', 'group_by' => ['member_gender'], 'from' => '2020').first[:text])
    expect(body).to eq('rows' => [{ 'value' => 3 }])
  end

  it 'only requires the form, and describes over_time as an object whose mode is required' do
    schema = described_class.input_schema
    expect(schema[:required]).to eq(['form'])
    expect(schema[:properties]['over_time']).to include(type: 'object', required: ['mode'])
    expect(schema[:properties]['over_time'][:properties][:mode][:enum]).to eq(Mcp::Aggregation::MODES.keys)
  end

  it 'shows the dataset and teaches the modes in its description' do
    text = described_class.definition[:description]
    expect(text).to include('active_at_end', 'spread', 'by_date', 'record_form', 'excluded')
  end
end
