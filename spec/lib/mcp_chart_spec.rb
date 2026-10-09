# frozen_string_literal: true

require 'rexml/document'

# The chart renderer (lib/mcp/widgets/chart.rb) and the two tools built on it. The renderer draws from a tidy
# table and knows nothing about members or funding; the tools take a QUERY, so these specs stub the
# aggregation and check what comes out.
RSpec.describe Mcp::Widgets::Chart do
  let(:words) { described_class::WORDS['en'] }
  let(:es) { described_class::WORDS['es'] }
  let(:theme) { Mcp::Theme.new('series' => %w[#007336 #c58b00 #2a78b5 #68af27]) }

  def table(x, **series)
    described_class::Table.new(x_labels: x, series: series.map { |label, values| { label: label.to_s, values: values.map(&:to_f) } })
  end

  def render(tbl, style: 'stacked', **opts)
    described_class.render(table: tbl, style: style, theme: theme, **opts)
  end

  def dims(svg)
    root = REXML::Document.new(svg).root
    [root.attributes['width'].to_i, root.attributes['height'].to_i]
  end

  describe '.nice_ticks' do
    it 'gives round steps from zero to the first value at or above the maximum' do
      expect(described_class.nice_ticks(203)).to eq([0, 50, 100, 150, 200, 250])
      expect(described_class.nice_ticks(100)).to eq([0, 20, 40, 60, 80, 100])
      expect(described_class.nice_ticks(7)).to eq([0, 2, 4, 6, 8])
      expect(described_class.nice_ticks(1_240_000).last).to be >= 1_240_000
    end

    it 'copes with nothing to show and with tiny numbers' do
      expect(described_class.nice_ticks(0)).to eq([0, 1])
      expect(described_class.nice_ticks(0.8).last).to be >= 0.8
    end
  end

  describe 'number formats' do
    it 'groups thousands and shortens big numbers, in each language' do
      expect(described_class.fmt(1234, words)).to eq('1,234')
      expect(described_class.fmt(1234, es)).to eq('1.234')
      expect(described_class.fmt(12_500, words, compact: true)).to eq('12.5 k')
      expect(described_class.fmt(12_500, es, compact: true)).to eq('12,5 mil')
      expect(described_class.fmt(2_500_000, words, compact: true)).to eq('2.5 M')
      expect(described_class.fmt(7, words)).to eq('7')
      expect(described_class.fmt(12.5, words)).to eq('12.5')
      expect(described_class.fmt(12.5, es)).to eq('12,5')
      expect(described_class.fmt(-1234, words)).to eq('-1,234')
    end

    it 'writes the numbers file without grouping, with the language\'s decimal mark' do
      expect(described_class.plain(1234.5, words)).to eq('1234.5')
      expect(described_class.plain(1234.5, es)).to eq('1234,5')
      expect(described_class.plain(3.0, words)).to eq('3')
    end
  end

  describe '.table_from_rows' do
    def rows_for(data)
      data.flat_map { |period, groups| groups.map { |label, v| { period: period, group: label.downcase, label: label, value: v } } }
    end

    it 'puts years on the x axis and categories in series, biggest first, filling gaps with zero' do
      tbl = described_class.table_from_rows(rows_for('2023' => { 'Male' => 5, 'Female' => 9 }, '2024' => { 'Female' => 4 }), words: words)
      expect(tbl.x_labels).to eq(%w[2023 2024])
      expect(tbl.series.map { |s| s[:label] }).to eq(%w[Female Male])
      expect(tbl.series.find { |s| s[:label] == 'Male' }[:values]).to eq([5.0, 0.0])
    end

    it 'sorts years as numbers' do
      tbl = described_class.table_from_rows(rows_for('2009' => { 'a' => 1 }, '2010' => { 'a' => 1 }), words: words)
      expect(tbl.x_labels).to eq(%w[2009 2010])
    end

    it 'joins two category levels into one series label when there are years' do
      rows = [{ period: '2024', group: %w[a x], label: %w[A X], value: 3 }]
      expect(described_class.table_from_rows(rows, words: words).series.first[:label]).to eq('A / X')
    end

    it 'names missing values with the language\'s word and puts them last' do
      rows = rows_for('2024' => { '(none)' => 50, 'Big' => 5, 'Small' => 1 })
      expect(described_class.table_from_rows(rows, words: words).series.map { |s| s[:label] }).to eq(['Big', 'Small', '(none)'])
      expect(described_class.table_from_rows(rows, words: es).series.last[:label]).to eq('(sin valor)')
    end

    it 'merges the smallest categories into Other when there are more than top_n' do
      rows = rows_for('2024' => { 'a' => 10, 'b' => 8, 'c' => 6, 'd' => 4, 'e' => 2, 'f' => 1 })
      tbl = described_class.table_from_rows(rows, top_n: 4, words: words)
      expect(tbl.series.map { |s| s[:label] }).to eq(%w[a b c Other])
      expect(tbl.series.last[:values]).to eq([7.0]) # d + e + f
    end

    it 'keeps (none) as its own series when merging' do
      rows = rows_for('2024' => { 'a' => 10, 'b' => 8, 'c' => 6, 'd' => 1, '(none)' => 3 })
      expect(described_class.table_from_rows(rows, top_n: 3, words: words).series.map { |s| s[:label] }).to eq(['a', 'Other', '(none)'])
    end

    it 'without years: one category level gives bars biggest first' do
      rows = [{ group: 'a', label: 'A', value: 2 }, { group: 'b', label: 'B', value: 9 }, { group: 'c', label: 'C', value: 5 }]
      tbl = described_class.table_from_rows(rows, words: words, single_label: 'Records')
      expect(tbl.x_labels).to eq(%w[B C A])
      expect(tbl.series.map { |s| s[:label] }).to eq(['Records'])
    end

    it 'without years: two levels give the first on the axis and the second as series' do
      rows = [{ group: %w[x f], label: %w[X F], value: 3 }, { group: %w[x m], label: %w[X M], value: 1 }, { group: %w[y f], label: %w[Y F], value: 9 }]
      tbl = described_class.table_from_rows(rows, words: words)
      expect(tbl.x_labels).to eq(%w[Y X])
      expect(tbl.series.map { |s| s[:label] }).to eq(%w[F M])
    end

    it 'without years: caps the categories on the axis, merging the tail into Other' do
      rows = (1..20).map { |i| { group: "g#{i}", label: "G#{i}", value: 21 - i } }
      tbl = described_class.table_from_rows(rows, words: words, max_x: 6)
      expect(tbl.x_labels).to eq(%w[G1 G2 G3 G4 G5 Other])
      expect(tbl.series.first[:values].last).to eq((6..20).sum { |i| 21 - i }.to_f)
    end
  end

  describe '.render' do
    let(:tbl) { table(%w[2023 2024 2025], Female: [10, 20, 30], Male: [5, 15, 10]) }

    it 'draws every style as valid standalone SVG, with a legend, hover text and no unresolved variables' do
      described_class::STYLES.each do |style|
        out = render(tbl, style: style, title: 'T')
        expect { REXML::Document.new(out[:svg]) }.not_to raise_error
        expect(out[:svg]).not_to include('var(')
        expect(out[:svg]).to include('>Female</text>', '>Male</text>', '2023', '<title>')
        expect(out[:html]).to include('<svg viewBox=', '>Download SVG</a>')
      end
    end

    it 'uses the shape each style needs' do
      expect(render(tbl, style: 'line')[:svg]).to include('<polyline')
      expect(render(tbl, style: 'area')[:svg]).to include('<polygon')
      expect(render(tbl, style: 'bar')[:svg].scan('<rect x=').size).to be >= 6 + 2 # six bars and the legend swatches
    end

    it 'shows totals above stacked bars and shares in percent charts' do
      expect(render(tbl, style: 'stacked')[:svg]).to include('class="tot"', '>40</text>') # 30 + 10 in the last year
      percent = render(tbl, style: 'percent')[:svg]
      expect(percent).to include('100 %', '67%') # 10 of 15 in the first year
    end

    it 'takes its colours from the theme, a fixed colour for a named category' do
      out = render(tbl)[:svg]
      expect(out).to include('fill:#007336', 'fill:#c58b00')
      named = described_class.render(table: tbl, style: 'bar', theme: Mcp::Theme.new('series' => %w[#111111 #222222], 'categories' => { 'male' => '#abcdef' }))
      expect(named[:svg]).to include('fill:#abcdef', 'fill:#111111')
    end

    it 'sizes each shape exactly: 960x540 for a slide and 720x480 for a report, whatever the title and notes' do
      [[nil, []], ['A title', ['A short note.']], ['A title', ['word ' * 80]]].each do |title, notes|
        slide = render(tbl, shape: 'slide', title: title, notes: notes)
        report = render(tbl, shape: 'report', title: title, notes: notes)
        expect(dims(slide[:svg])).to eq([960, 540])
        expect(dims(report[:svg])).to eq([720, 480])
        expect(dims(slide[:variants].first[:svg])).to eq([720, 480])
        expect(dims(report[:variants].first[:svg])).to eq([960, 540])
      end
    end

    it 'wraps the caption inside the picture, narrower for the narrower shape' do
      out = render(tbl, shape: 'report', title: 'T', notes: ["#{'word ' * 60}end"])
      lines = out[:svg].scan(%r{<text class="note"[^>]*>([^<]*)</text>}).flatten
      expect(lines.size).to be >= 3
      expect(lines.map(&:length).max).to be <= Mcp::Widgets::Frame.note_chars(720)
    end

    it 'offers the other shape, and the numbers, as downloads' do
      out = render(tbl, title: 'Staff by year', shape: 'slide')
      expect(out[:html]).to include('id="dlsvg2" download="staff-by-year-report-3-2.svg"', 'Download PNG (report 3:2)', 'id="dltsv" download="staff-by-year.tsv"', 'Download the numbers')
      expect(render(tbl, shape: 'report')[:html]).to include('Download SVG (slide 16:9)')
    end

    it 'writes the numbers as tab-separated text Excel opens, with the given heading' do
      out = render(tbl, x_title: 'Year')
      expect(out[:tsv]).to eq("Year\tFemale\tMale\n2023\t10\t5\n2024\t20\t15\n2025\t30\t10\n")
      encoded = out[:html][/data:text\/tab-separated-values;charset=utf-8;base64,([^"]+)"/, 1]
      expect(encoded.unpack1('m').force_encoding('UTF-8')).to eq("﻿#{out[:tsv]}")
    end

    it 'speaks Spanish: heading, links, numbers' do
      out = described_class.render(table: table(%w[2024], 'A' => [1234.5]), style: 'bar', theme: theme, language: 'es', title: 'T', shape: 'slide')
      expect(out[:html]).to include('Descargar SVG', 'Descargar los datos', 'Descargar PNG (informe 3:2)')
      expect(out[:tsv]).to include("Categoría\tA", "2024\t1234,5")
    end

    it 'escapes labels and the heading' do
      out = render(table(['<x>'], '<b>&' => [3]), title: '<script>', y_label: '"q"')
      expect(out[:svg]).to include('&lt;x&gt;', '&lt;b&gt;&amp;', '&lt;script&gt;')
      expect(out[:svg]).not_to include('<b>&')
    end

    it 'thins the x labels when there are too many to read' do
      many = table((1990..2025).map(&:to_s), A: (1..36).to_a)
      shown = render(many, shape: 'report')[:svg].scan(/class="xl"/).size
      expect(shown).to be < 36
      expect(shown).to be > 8
    end

    it 'names every bar of a category chart, at a slant when the names do not fit side by side' do
      names = (1..12).map { |i| "Category with a long name #{i}" }
      svg = render(table(names, A: (1..12).to_a), style: 'bar', shape: 'report')[:svg]
      expect(svg.scan('class="xl"').size).to eq(12)
      expect(svg).to include('transform="rotate(-40')
      shown = svg.scan(%r{rotate\(-40[^>]*>([^<]*)</text>}).flatten
      expect(shown).to all(end_with('…')) # long names are cut with an ellipsis
      expect(shown.map(&:length).max).to be <= described_class::MAX_LABEL
    end

    it 'keeps short category names upright' do
      svg = render(table(%w[Spain Italy France], A: [3, 2, 1]), style: 'bar')[:svg]
      expect(svg.scan('class="xl"').size).to eq(3)
      expect(svg).not_to include('rotate(')
    end

    it 'shows values on bars only when they fit' do
      expect(render(tbl, style: 'bar')[:svg]).to include('class="val"')
      wide = table((1..40).map(&:to_s), A: (1..40).to_a, B: (1..40).to_a)
      expect(render(wide, style: 'bar')[:svg]).not_to include('class="val"')
    end

    it 'wraps a long legend onto more rows without hiding the chart' do
      series = (1..10).to_h { |i| ["A fairly long category name number #{i}", [i]] }
      out = render(table(%w[2024], **series.transform_keys(&:to_sym)), style: 'stacked')
      expect(out[:svg].scan('rx="2"').size).to eq(10)
      expect { REXML::Document.new(out[:svg]) }.not_to raise_error
    end

    describe 'refuses what cannot be drawn, saying why' do
      it('an unknown style') { expect { render(tbl, style: 'pie') }.to raise_error(Mcp::ToolError, /style must be one of: bar, stacked, percent, line, area/) }
      it('an unknown shape') { expect { render(tbl, shape: 'poster') }.to raise_error(Mcp::ToolError, /shape must be one of: slide, report/) }
      it('no data') { expect { render(described_class::Table.new(x_labels: [], series: [])) }.to raise_error(Mcp::ToolError, /nothing to chart/) }
      it('too many points') { expect { render(table((1..200).map(&:to_s), A: (1..200).to_a)) }.to raise_error(Mcp::ToolError, /Too many points/) }
    end

    it 'draws all zeros without breaking' do
      expect { REXML::Document.new(render(table(%w[2024], A: [0]))[:svg]) }.not_to raise_error
    end
  end
end

RSpec.describe Mcp::Tools::ChartOverTime do
  let(:data) do
    { form: 'member', measure: 'count', by: ['member_gender'], by_labels: ['Gender'], records_considered: 924, as_of: '2026-10-09',
      over_time: { mode: 'active_at_end', granularity: 'year', fields: %w[member_start_date member_end_date] },
      excluded: { 'no member_start_date' => 5 },
      rows: [{ period: '2024', group: 'female', label: 'Female', value: 96 }, { period: '2024', group: 'male', label: 'Male', value: 83 },
             { period: '2025', group: 'female', label: 'Female', value: 85 }, { period: '2025', group: 'male', label: 'Male', value: 67 }] }
  end
  let(:query) { { 'form' => 'member', 'group_by' => ['member_gender'], 'over_time' => { 'mode' => 'active_at_end', 'start_field' => 'member_start_date' }, 'title' => 'Members by gender' } }

  before do
    allow(Mcp::Records::Context).to receive(:new).and_wrap_original do |original|
      original.call.tap { |c| allow(c).to receive(:form!).and_return(Mcp::Records::FormInfo.new(name: 'member', storage: 'member', label: 'Member')) }
    end
    allow(Mcp::Aggregation).to receive(:run).and_return(data)
  end

  def run(extra = {})
    content = described_class.invoke(query.merge(extra))
    [content, JSON.parse(content.first[:text])]
  end

  it 'passes the query to the aggregation, and draws what comes back' do
    expect(Mcp::Aggregation).to receive(:run).with(hash_including(group_by: ['member_gender'], over_time: query['over_time'])).and_return(data)
    content, summary = run
    expect(content.map { |b| b[:type] }).to eq(%w[text resource])
    html = content.last[:resource][:text]
    expect(content.last[:resource][:uri]).to start_with('ui://chart/')
    expect(html).to include('Members by gender', 'Download the numbers', '>Female</text>')
    expect(summary).to include('style' => 'stacked', 'shape' => 'slide', 'x' => %w[2024 2025], 'measure' => 'count', 'as_of' => '2026-10-09')
    expect(summary['series']).to eq([{ 'label' => 'Female', 'values' => [96.0, 85.0] }, { 'label' => 'Male', 'values' => [83.0, 67.0] }])
  end

  it 'says in the caption what was asked, as of when, and what was left out' do
    html = run[0].last[:resource][:text]
    expect(html).to include('Count of Member records by Gender', 'on the books at the end of each year',
                            'Data as of 2026-10-09; 924 records read', 'Left out for lacking a needed field: 5 (no member_start_date)',
                            'The current year (') # an end-of-year headcount warns that the year in progress is partial
  end

  it 'chooses bar for one series and stacked for several, unless told' do
    allow(Mcp::Aggregation).to receive(:run).and_return(data.merge(by: [], rows: [{ period: '2024', value: 3 }, { period: '2025', value: 4 }]))
    expect(run[1]['style']).to eq('bar')
    allow(Mcp::Aggregation).to receive(:run).and_return(data)
    expect(run[1]['style']).to eq('stacked')
    expect(run('style' => 'line')[1]['style']).to eq('line')
  end

  it 'honours the shape, the title heading and a custom axis label' do
    html = run('shape' => 'report', 'y_label' => 'Heads')[0].last[:resource][:text]
    expect(html).to include('Heads', 'Download SVG (slide 16:9)')
  end

  it 'draws in the language asked for' do
    html = run('language' => 'es')[0].last[:resource][:text]
    expect(html).to include('Datos a fecha', 'Descargar los datos')
  end

  it 'returns a PNG attachment instead of the page when asked and possible' do
    allow(Mcp::Widgets::Raster).to receive(:png).and_return("\x89PNG\r\n\x1a\nxx".b)
    content, summary = run('output' => 'png')
    expect(content.map { |b| b[:type] }).to eq(%w[text image])
    expect(summary['attached']).to eq('html' => false, 'png' => true)
  end

  it 'falls back to the page when a PNG was asked for but cannot be made' do
    allow(Mcp::Widgets::Raster).to receive(:png).and_return(nil)
    expect(run('output' => 'png')[0].map { |b| b[:type] }).to eq(%w[text resource])
  end

  it 'asks for over_time, pointing to the other tool' do
    expect { described_class.invoke(query.reject { |k, _| k == 'over_time' }) }.to raise_error(Mcp::ToolError, /over_time is required.*chart_breakdown/)
  end

  it 'refuses an unknown output' do
    expect { run('output' => 'gif') }.to raise_error(Mcp::ToolError, /output must be one of: html, png, both/)
  end

  it 'describes itself for a small model: a question-shaped summary and the query fields' do
    expect(described_class.summary).to match(/how a number changes over the years/i)
    expect(described_class.input_schema[:properties].keys).to include('form', 'over_time', 'group_by', 'style', 'shape', 'title', 'top_n')
  end
end

RSpec.describe Mcp::Tools::ChartBreakdown do
  let(:data) do
    { form: 'member', measure: 'count', by: %w[member_category member_gender], by_labels: %w[Category Gender], records_considered: 96, as_of: '2026-10-09',
      rows: [{ group: %w[a f], label: ['Postdocs', 'Female'], value: 20 }, { group: %w[a m], label: %w[Postdocs Male], value: 10 },
             { group: %w[b f], label: ['PhD students', 'Female'], value: 5 }, { group: %w[b m], label: ['PhD students', 'Male'], value: 15 }] }
  end

  before do
    allow(Mcp::Records::Context).to receive(:new).and_wrap_original do |original|
      original.call.tap { |c| allow(c).to receive(:form!).and_return(Mcp::Records::FormInfo.new(name: 'member', storage: 'member', label: 'Member')) }
    end
    allow(Mcp::Aggregation).to receive(:run).and_return(data)
  end

  def run(args = {})
    content = described_class.invoke({ 'form' => 'member', 'group_by' => %w[member_category member_gender] }.merge(args))
    [content, JSON.parse(content.first[:text])]
  end

  it 'draws shares by default for two levels, with the first level on the axis' do
    _, summary = run
    expect(summary).to include('style' => 'percent', 'x' => ['Postdocs', 'PhD students'])
    expect(summary['series'].map { |s| s['label'] }).to eq(%w[Female Male])
  end

  it 'draws plain bars for one level, biggest first' do
    allow(Mcp::Aggregation).to receive(:run).and_return(data.merge(by: ['member_category'], rows: [{ group: 'a', label: 'Few', value: 2 }, { group: 'b', label: 'Many', value: 9 }]))
    _, summary = run('group_by' => ['member_category'])
    expect(summary).to include('style' => 'bar', 'x' => %w[Many Few])
  end

  it 'never passes years to the aggregation' do
    expect(Mcp::Aggregation).to receive(:run).with(hash_including(over_time: nil, from: nil, to: nil)).and_return(data)
    run('over_time' => { 'mode' => 'by_date' }, 'from' => '2020')
  end

  it 'has no years in its caption and needs a group' do
    expect(run[0].last[:resource][:text]).to include('Count of Member records by Category / Gender')
    expect { described_class.invoke('form' => 'member') }.to raise_error(Mcp::ToolError, /Missing required argument\(s\): group_by/)
    expect { described_class.run('form' => 'member', 'group_by' => ['']) }.to raise_error(Mcp::ToolError, /group_by is required.*chart_over_time/)
  end

  it 'describes itself as the question "what is it made up of"' do
    expect(described_class.summary).to match(/made up of/i)
    expect(described_class.input_schema[:required]).to include('form', 'group_by')
  end
end
