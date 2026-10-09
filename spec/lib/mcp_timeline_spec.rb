# frozen_string_literal: true

# The generic timeline widget (lib/mcp/widgets/timeline.rb) and the tool that
# exposes it. The widget takes rows of {label, start, end, lane} and knows
# nothing about what they mean.
RSpec.describe Mcp::Widgets::Timeline do
  let(:today) { Date.new(2026, 10, 8) }

  def render(rows, **opts)
    described_class.render(rows: rows, today: today, **opts)
  end

  it 'draws bars, points and an ongoing bar, grouped into lanes in order of first appearance' do
    out = render([
                   { 'lane' => 'Funding', 'label' => 'ALFA', 'start' => '2024-01-01', 'end' => '2025-06-30' },
                   { 'lane' => 'Papers', 'label' => 'Paper', 'start' => '2025-03-12' },
                   { 'lane' => 'Funding', 'label' => 'BETA', 'start' => '2025-07-01', 'ongoing' => true }
                 ], title: 'Ana')
    expect(out[:rows]).to eq(3)
    expect(out[:lanes]).to eq(%w[Funding Papers])
    expect(out[:html]).to include('<h1>Ana</h1>', '<polygon', 'ongoing', 'class="today"')
    expect(out[:html].scan('<rect x=').size).to eq(2) # two bars (ALFA, BETA)
  end

  it 'runs an ongoing bar to today, so the range ends at today plus padding' do
    out = render([{ 'label' => 'x', 'start' => '2026-01-01', 'ongoing' => true }])
    expect(Date.iso8601(out[:to])).to be >= today
    expect(Date.iso8601(out[:from])).to be <= Date.new(2026, 1, 1)
  end

  it 'does not draw an ongoing row that has not started yet as running backwards' do
    out = render([{ 'label' => 'later', 'start' => '2026-12-01', 'ongoing' => true }])
    expect(Date.iso8601(out[:to])).to be >= Date.new(2026, 12, 1)
    expect(out[:html]).to include('<polygon').or include('<rect x=')
  end

  it 'does not extend a finished row to today' do
    out = render([{ 'label' => 'x', 'start' => '2020-01-01', 'end' => '2020-12-31' }])
    expect(Date.iso8601(out[:to])).to be < Date.new(2021, 3, 1)
    expect(out[:html]).not_to include('class="today"')
  end

  it 'accepts a full timestamp and the word today as dates' do
    out = render([{ 'label' => 'x', 'start' => '2025-09-29T19:42:11.736451Z', 'end' => 'today' }])
    expect(out[:from]).to start_with('2025-09')
  end

  it 'escapes text from the rows so a label cannot inject markup' do
    out = render([{ 'label' => '<script>alert(1)</script>', 'start' => '2025-01-01', 'detail' => '"><img>' }])
    expect(out[:html]).not_to include('<script>alert')
    expect(out[:html]).to include('&lt;script&gt;alert(1)&lt;/script&gt;')
    expect(out[:html]).not_to include('"><img>')
  end

  it 'gives a lone point a usable range' do
    out = render([{ 'label' => 'x', 'start' => '2025-01-01' }])
    expect(Date.iso8601(out[:from])).to be < Date.iso8601(out[:to])
  end

  it 'puts rows with no lane in one default lane' do
    expect(render([{ 'label' => 'x', 'start' => '2025-01-01' }])[:lanes]).to eq(['Events'])
  end

  describe 'rejects bad input with a message that says what to fix' do
    it('no rows') { expect { render([]) }.to raise_error(Mcp::ToolError, /non-empty list/) }
    it('not a list') { expect { render('x') }.to raise_error(Mcp::ToolError, /non-empty list/) }
    it('missing label') { expect { render([{ 'start' => '2025-01-01' }]) }.to raise_error(Mcp::ToolError, /Row 1 has no label/) }
    it('missing start') { expect { render([{ 'label' => 'x' }]) }.to raise_error(Mcp::ToolError, /Row 1 \(x\)|row 1 start/) }
    it('invalid date') { expect { render([{ 'label' => 'x', 'start' => '2025-13-40' }]) }.to raise_error(Mcp::ToolError, /not a date/) }
    it('end before start') { expect { render([{ 'label' => 'x', 'start' => '2025-05-01', 'end' => '2025-01-01' }]) }.to raise_error(Mcp::ToolError, /end is before start/) }
    it('too many rows') do
      rows = Array.new(151) { |i| { 'label' => i.to_s, 'start' => '2025-01-01' } }
      expect { render(rows) }.to raise_error(Mcp::ToolError, /At most 150/)
    end
  end
end

RSpec.describe Mcp::Tools::RenderTimeline do
  it 'returns a summary text block and the widget as an HTML resource' do
    content = described_class.invoke('rows' => [{ 'label' => 'x', 'start' => '2025-01-01', 'end' => '2025-06-01' }], 'title' => 'T', 'output' => 'html')
    expect(content.map { |b| b[:type] }).to eq(%w[text resource])
    expect(JSON.parse(content.first[:text])).to include('drawn' => 1)
    expect(content.last[:resource]).to include(mimeType: 'text/html')
    expect(content.last[:resource][:uri]).to start_with('ui://timeline/')
    expect(content.last[:resource][:text]).to start_with('<!doctype html>')
  end
end

RSpec.describe Mcp::Widgets::Timeline, 'label placement' do
  let(:today) { Date.new(2026, 10, 8) }

  def labels(rows)
    described_class.render(rows: rows, today: today)[:html].scan(%r{<text class="(lbl[^"]*)" x="([\d.]+)"[^>]*text-anchor="(\w+)"[^>]*>([^<]*)</text>})
  end

  it 'never starts a label left of the lane-name gutter' do
    long = 'A very long label that cannot fit anywhere near the start of the bar at all' * 2
    rows = [{ 'label' => long, 'start' => '2020-01-01', 'end' => '2026-06-01' }, { 'label' => 'x', 'start' => '2026-06-02' }]
    labels(rows).each do |_cls, x, anchor, _text|
      expect(anchor == 'end' ? x.to_f - 1 : x.to_f).to be >= described_class::LEFT
    end
  end

  it 'puts a label that fits on neither side inside a long bar, and cuts it to the bar' do
    rows = [{ 'label' => 'Alvarez Alfageme, Olga - UI-TEST project TWO (delete me)', 'start' => '2026-01-01', 'ongoing' => true },
            { 'label' => 'filler', 'start' => '2026-01-01', 'end' => '2026-02-01' }]
    cls, _x, _anchor, text = labels(rows).first
    expect(cls).to eq('lbl inbar')
    expect(text.length).to be <= 48
  end

  it 'leaves a short label beside its mark at full length' do
    rows = [{ 'label' => 'ALFA', 'start' => '2024-01-01', 'end' => '2024-03-01' }, { 'label' => 'x', 'start' => '2026-06-02' }]
    cls, _x, anchor, text = labels(rows).first
    expect([cls, anchor, text]).to eq(['lbl', 'start', 'ALFA'])
  end
end

RSpec.describe Mcp::Widgets::Timeline, 'in Spanish' do
  let(:today) { Date.new(2026, 10, 8) }
  let(:rows) { [{ 'label' => 'A', 'start' => '2026-01-01', 'ongoing' => true }, { 'label' => 'B', 'start' => '2026-03-01', 'end' => '2026-08-01' }] }

  it 'writes month names, the ongoing word and the page language in Spanish' do
    html = described_class.render(rows: rows, today: today, language: 'es')[:html]
    expect(html).to include('<html lang="es">', 'en curso')
    expect(html).to match(/>(ene|feb|mar|abr|may|jun|jul|ago|sep|oct|nov|dic)</)
    expect(html).not_to include('>Jan<', '>Apr<', 'ongoing')
  end

  it 'stays English by default and falls back to it for an unknown language' do
    expect(described_class.render(rows: rows, today: today)[:html]).to include('<html lang="en">', 'ongoing')
    expect(described_class.render(rows: rows, today: today, language: 'fr')[:html]).to include('<html lang="en">')
  end

  it 'accepts hoy as a date' do
    out = described_class.render(rows: [{ 'label' => 'x', 'start' => '2026-01-01', 'end' => 'hoy' }], today: today)
    expect(Date.iso8601(out[:to])).to be >= today
  end

  it 'gets its language from the tool call' do
    content = Mcp::Tools::RenderTimeline.invoke('rows' => rows, 'title' => 'T', 'language' => 'es')
    expect(content.last[:resource][:text]).to include('<html lang="es">')
  end
end

RSpec.describe Mcp::Widgets::Timeline, 'the today marker' do
  let(:today) { Date.new(2026, 10, 8) }
  let(:running) { [{ 'label' => 'A', 'start' => '2026-01-01', 'ongoing' => true }] }

  it 'is labelled, in the language of the chart' do
    expect(described_class.render(rows: running, today: today)[:html]).to match(%r{class="todaylbl"[^>]*>Today</text>})
    expect(described_class.render(rows: running, today: today, language: 'es')[:html]).to match(%r{class="todaylbl"[^>]*>Hoy</text>})
  end

  it 'is drawn only when today is inside the chart, and then there is no label either' do
    past = [{ 'label' => 'old', 'start' => '2020-01-01', 'end' => '2020-06-01' }]
    html = described_class.render(rows: past, today: today)[:html]
    expect(html).not_to include('class="today"')
    expect(html).not_to include('todaylbl"')
  end

  it 'keeps the label inside the picture when today is at the right edge' do
    html = described_class.render(rows: [{ 'label' => 'x', 'start' => '2026-01-01', 'end' => '2026-10-08' }], today: today)[:html]
    expect(html).to match(/class="todaylbl"[^>]*text-anchor="end"/)
  end
end

RSpec.describe Mcp::Widgets::Timeline, 'the saveable picture' do
  let(:today) { Date.new(2026, 10, 8) }
  let(:rows) do
    [{ 'lane' => 'Funding', 'label' => 'ALFA <b>&</b>', 'start' => '2026-01-01', 'ongoing' => true },
     { 'lane' => 'Papers', 'label' => 'Paper', 'start' => '2026-03-12' }]
  end

  def drawn(**opts)
    described_class.render(rows: rows, title: 'Álvarez Alfageme, Olga', today: today, **opts)
  end

  describe 'the standalone SVG' do
    it 'is well-formed XML with its own namespace and size, so it opens anywhere' do
      svg = drawn[:svg]
      doc = REXML::Document.new(svg)
      root = doc.root
      expect(root.namespace).to eq('http://www.w3.org/2000/svg')
      expect(root.attributes['width'].to_i).to be > 0
      expect(root.attributes['height'].to_i).to be > 0
      expect(root.attributes['viewBox']).to match(/\A0 0 \d+ \d+\z/)
    end

    it 'uses literal colours: no CSS variables or media queries (librsvg and editors do not all read them)' do
      svg = drawn[:svg]
      expect(svg).not_to include('var(', '@media', ':root')
      expect(svg).to include('#ffffff') # a white background rectangle, not transparency
    end

    it 'draws the title into the picture, and the today label' do
      svg = drawn[:svg]
      expect(svg).to include('>Álvarez Alfageme, Olga</text>')
      expect(svg).to include('>Today</text>')
      expect(drawn(language: 'es')[:svg]).to include('>Hoy</text>')
    end

    it 'escapes row text' do
      expect(drawn[:svg]).to include('ALFA &lt;b&gt;&amp;&lt;/b&gt;')
      expect(drawn[:svg]).not_to include('<b>')
    end

    it 'leaves room for the title only when there is one' do
      with = described_class.render(rows: rows, title: 'T', today: today)[:svg][/height="(\d+)"/, 1].to_i
      without = described_class.render(rows: rows, today: today)[:svg][/height="(\d+)"/, 1].to_i
      expect(with - without).to eq(described_class::TITLE_H)
    end
  end

  describe 'the download link on the page' do
    it 'carries exactly the standalone SVG, named after the title' do
      out = drawn
      link = out[:html].match(%r{<a id="dlsvg" download="([^"]+)" href="data:image/svg\+xml;base64,([^"]+)">([^<]+)</a>})
      expect(link).not_to be_nil
      expect(link[1]).to eq('alvarez-alfageme-olga.svg')
      expect(link[2].unpack1('m').force_encoding('UTF-8')).to eq(out[:svg])
      expect(link[3]).to eq('Download SVG')
    end

    it 'is in Spanish for a Spanish chart, with a Spanish default file name' do
      out = described_class.render(rows: rows, today: today, language: 'es')
      expect(out[:html]).to include('Descargar SVG', 'download="cronologia.svg"')
    end

    it 'falls back to a plain file name when the title has no usable letters' do
      expect(described_class.render(rows: rows, title: '¿¡!?', today: today)[:html]).to include('download="timeline.svg"')
    end
  end
end

RSpec.describe Mcp::Widgets::Raster do
  let(:svg) { '<svg xmlns="http://www.w3.org/2000/svg" width="10" height="10"/>' }
  let(:png) { "\x89PNG\r\n\x1a\nrest".b }
  let(:ok) { instance_double(Process::Status, success?: true, exitstatus: 0) }
  let(:failed) { instance_double(Process::Status, success?: false, exitstatus: 1) }

  before { allow(described_class).to receive(:warn) }

  it 'feeds the SVG to rsvg-convert on stdin and returns the PNG bytes' do
    expect(Open3).to receive(:capture3).with('rsvg-convert', '--format=png', '--width=1920', '--background-color=white',
                                             hash_including(stdin_data: svg, binmode: true)).and_return([png, '', ok])
    expect(described_class.png(svg)).to eq(png)
  end

  it 'gives nil, not an error, when the program is not installed' do
    allow(Open3).to receive(:capture3).and_raise(Errno::ENOENT)
    expect(described_class.png(svg)).to be_nil
  end

  it 'gives nil when the program fails or prints something that is not a PNG' do
    allow(Open3).to receive(:capture3).and_return(['', 'bad svg', failed])
    expect(described_class.png(svg)).to be_nil
    allow(Open3).to receive(:capture3).and_return(['not a png', '', ok])
    expect(described_class.png(svg)).to be_nil
  end

  it 'gives nil when it takes too long' do
    allow(Timeout).to receive(:timeout).and_raise(Timeout::Error)
    expect(described_class.png(svg)).to be_nil
  end

  it 'really renders a PNG when rsvg-convert is installed here (skipped otherwise)' do
    skip 'rsvg-convert is not installed on this machine' unless system('which rsvg-convert > /dev/null 2>&1')

    svg = Mcp::Widgets::Timeline.render(rows: [{ 'label' => 'Álvarez', 'start' => '2026-01-01' }], today: Date.new(2026, 10, 8))[:svg]
    expect(described_class.png(svg)).to start_with("\x89PNG".b)
  end
end

RSpec.describe Mcp::Tools::RenderTimeline, 'outputs' do
  let(:rows) { [{ 'label' => 'x', 'start' => '2025-01-01', 'end' => '2025-06-01' }] }
  let(:png) { "\x89PNG\r\n\x1a\nbytes".b }

  def run(extra = {})
    content = described_class.invoke({ 'rows' => rows, 'title' => 'T' }.merge(extra))
    [content, JSON.parse(content.first[:text])]
  end

  context 'when a PNG can be made' do
    before { allow(Mcp::Widgets::Raster).to receive(:png).and_return(png) }

    it 'attaches the widget and a PNG image for both' do
      content, summary = run('output' => 'both')
      expect(content.map { |b| b[:type] }).to eq(%w[text resource image])
      expect(content.last).to eq(type: 'image', data: Base64.strict_encode64(png), mimeType: 'image/png')
      expect(summary['attached']).to eq('html' => true, 'png' => true)
      expect(summary['note']).to include('PNG', 'Download SVG', 'Download PNG')
    end

    it 'attaches only the PNG when that is all that was asked for' do
      content, summary = run('output' => 'png')
      expect(content.map { |b| b[:type] }).to eq(%w[text image])
      expect(summary['attached']).to eq('html' => false, 'png' => true)
    end

    it 'attaches only the widget by default, and never rasterizes' do
      expect(Mcp::Widgets::Raster).not_to receive(:png)
      content, summary = run
      expect(content.map { |b| b[:type] }).to eq(%w[text resource])
      expect(summary['attached']).to eq('html' => true, 'png' => false)
      expect(summary['note']).to include('Download SVG', 'Download PNG')
    end

    it 'attaches only the widget for html, and never rasterizes' do
      expect(Mcp::Widgets::Raster).not_to receive(:png)
      content, summary = run('output' => 'html')
      expect(content.map { |b| b[:type] }).to eq(%w[text resource])
      expect(summary['attached']).to eq('html' => true, 'png' => false)
    end
  end

  context 'when no PNG can be made on this server' do
    before { allow(Mcp::Widgets::Raster).to receive(:png).and_return(nil) }

    it 'still gives the widget for both, and says so' do
      content, summary = run('output' => 'both')
      expect(content.map { |b| b[:type] }).to eq(%w[text resource])
      expect(summary['attached']).to eq('html' => true, 'png' => false)
    end

    it 'falls back to the widget for png and tells the model why' do
      content, summary = run('output' => 'png')
      expect(content.map { |b| b[:type] }).to eq(%w[text resource])
      expect(summary['note']).to include('PNG could not be made', 'Download SVG')
    end
  end

  it 'refuses an unknown output, listing the choices' do
    expect { described_class.invoke('rows' => rows, 'output' => 'gif') }.to raise_error(Mcp::ToolError, /html, png, both/)
  end

  it 'offers the output choice in the schema' do
    expect(described_class.input_schema[:properties]['output'][:enum]).to eq(%w[html png both])
  end
end

RSpec.describe Mcp::Widgets::Timeline, 'the page makes its own PNG' do
  let(:out) { described_class.render(rows: [{ 'label' => 'x', 'start' => '2026-01-01', 'ongoing' => true }], title: 'Álvarez, Olga', today: Date.new(2026, 10, 8)) }

  it 'has a Download PNG link that is hidden until a script shows it (a sandboxed frame never shows a dead link)' do
    expect(out[:html]).to match(/<a id="dlpng" data-name="alvarez-olga\.png" href="#" hidden>Download PNG<\/a>/)
    expect(out[:html]).to include('pngLink.hidden=false', 'canvas', 'toBlob', 'image/png')
  end

  it 'draws the page\'s own SVG link, at twice the size, on a white background' do
    expect(out[:html]).to include('svgLink.href', '*2', "fillStyle='#fff'")
  end

  it 'loads nothing from outside: one inline script, no external sources' do
    expect(out[:html].scan('<script').size).to eq(1)
    expect(out[:html]).not_to match(/<script[^>]*src=|<link |src="https?:|href="https?:/)
  end

  it 'says it in Spanish too' do
    html = described_class.render(rows: [{ 'label' => 'x', 'start' => '2026-01-01' }], title: 'Álvarez', today: Date.new(2026, 10, 8), language: 'es')[:html]
    expect(html).to include('Descargar PNG', 'data-name="alvarez.png"')
  end
end
