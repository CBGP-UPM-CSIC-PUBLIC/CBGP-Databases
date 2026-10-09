# frozen_string_literal: true

require 'tmpdir'

# The chart theme (lib/mcp/theme.rb): a YAML file a deployment edits to brand its charts. The file is
# untrusted text that ends up inside SVG and CSS, so every value is validated, and anything wrong falls
# back to the built-in default for that value instead of stopping a chart.
RSpec.describe Mcp::Theme do
  around do |example|
    Dir.mktmpdir do |dir|
      @dir = dir
      original = ENV.fetch('CBGP_THEME_FILE', nil)
      described_class.reset!
      example.run
    ensure
      ENV['CBGP_THEME_FILE'] = original
      described_class.reset!
    end
  end

  before { allow(described_class).to receive(:warn) }

  def write_theme(yaml, name = 'theme.yml')
    path = File.join(@dir, name)
    File.write(path, yaml)
    ENV['CBGP_THEME_FILE'] = path
    path
  end

  describe 'the built-in default' do
    it 'is the CBGP look: CBGP green first, with enough distinct colours for a busy chart' do
      theme = described_class.default
      expect(theme.series.first).to eq('#007336')
      expect(theme.series.uniq.size).to be >= 8
      expect(theme.light['bg']).to eq('#ffffff')
      expect(theme.dark['bg']).to eq('#161b22')
      expect(theme.footer).to be_nil
    end

    it 'is what a missing file gives' do
      ENV['CBGP_THEME_FILE'] = File.join(@dir, 'absent.yml')
      expect(described_class.current.series).to eq(described_class::DEFAULT_SERIES)
    end
  end

  describe 'reading a file' do
    it 'takes colours, series, categories, font, footer and name from it' do
      write_theme(<<~YAML)
        name: Test Institute
        font: Georgia, serif
        colors: { background: "#fafafa", text: "#111", highlight: "#ff0000" }
        series: ["#123456", "#abcdef", "#0a0"]
        categories: { European: "#2a78b5" }
        dark: { background: "#000000" }
        footer: Source - the test database
      YAML
      theme = described_class.current
      expect(theme.name).to eq('Test Institute')
      expect(theme.font).to eq('Georgia, serif')
      expect(theme.light).to include('bg' => '#fafafa', 'fg' => '#111', 'hl' => '#ff0000', 'muted' => described_class::DEFAULT_LIGHT['muted'])
      expect(theme.dark['bg']).to eq('#000000')
      expect(theme.series).to eq(%w[#123456 #abcdef #0a0])
      expect(theme.categories).to eq('european' => '#2a78b5')
      expect(theme.footer).to eq('Source - the test database')
      expect(theme.problems).to be_empty
    end

    it 'reads the file again when it changes, without a restart' do
      path = write_theme("series: ['#111111', '#222222']\n")
      expect(described_class.current.series).to eq(%w[#111111 #222222])
      File.write(path, "series: ['#333333', '#444444']\n")
      File.utime(Time.now + 5, Time.now + 5, path) # a distinct modification time
      expect(described_class.current.series).to eq(%w[#333333 #444444])
    end

    it 'does not re-read an unchanged file' do
      write_theme("series: ['#111111', '#222222']\n")
      first = described_class.current
      expect(described_class.current).to equal(first)
    end

    it 'falls back to the default for a file that is not valid YAML or not a mapping' do
      write_theme("series: [unclosed\n")
      expect(described_class.current.series).to eq(described_class::DEFAULT_SERIES)
      described_class.reset!
      write_theme("- just\n- a list\n")
      expect(described_class.current.series).to eq(described_class::DEFAULT_SERIES)
    end

    it 'refuses YAML that tries to build objects or use aliases' do
      write_theme("series: !ruby/object:OpenStruct {}\n")
      expect(described_class.current.series).to eq(described_class::DEFAULT_SERIES)
    end

    it 'finds the file named by CBGP_THEME_FILE, else theme/theme.yml next to the application' do
      ENV['CBGP_THEME_FILE'] = ''
      expect(described_class.path).to eq(described_class::DEFAULT_PATH)
      expect(described_class::DEFAULT_PATH).to end_with('/theme/theme.yml')
    end
  end

  describe 'validation (the file is untrusted text)' do
    it 'ignores a colour that is not #rgb or #rrggbb, keeping that default and noting it' do
      theme = described_class.new('colors' => { 'background' => 'red', 'text' => '#12', 'grid' => '#dfe5df' })
      expect(theme.light['bg']).to eq(described_class::DEFAULT_LIGHT['bg'])
      expect(theme.light['fg']).to eq(described_class::DEFAULT_LIGHT['fg'])
      expect(theme.light['grid']).to eq('#dfe5df')
      expect(theme.problems.size).to eq(2)
    end

    it 'cannot be used to inject markup or style rules through a colour' do
      evil = ['#fff;} body{display:none', '#fff" onload="alert(1)', '</style><script>x</script>', 'url(javascript:x)']
      theme = described_class.new('colors' => { 'background' => evil[0], 'text' => evil[1], 'muted' => evil[2], 'grid' => evil[3] },
                                  'series' => evil + ['#111111', '#222222'], 'categories' => { 'x' => evil[0] })
      colours = theme.light.values + theme.dark.values + theme.series + theme.categories.values
      expect(colours).to all(match(described_class::COLOUR))
      expect(theme.series).to eq(%w[#111111 #222222])
      expect(theme.categories).to eq({})
    end

    it 'accepts only a plain list of font names' do
      expect(described_class.new('font' => 'Calibri, "Open Sans", Arial').font).to eq('Calibri, "Open Sans", Arial')
      %w[a;b a{b} a<b> a(b)].each do |bad|
        expect(described_class.new('font' => bad).font).to eq(described_class::DEFAULT_FONT)
      end
      expect(described_class.new('font' => 'x' * 200).font).to eq(described_class::DEFAULT_FONT)
    end

    it 'needs at least two valid series colours, and keeps at most 24' do
      expect(described_class.new('series' => ['#111111']).series).to eq(described_class::DEFAULT_SERIES)
      expect(described_class.new('series' => 'blue').series).to eq(described_class::DEFAULT_SERIES)
      many = Array.new(40) { |i| format('#%06x', i * 1000 + 100) }
      expect(described_class.new('series' => many).series.size).to eq(24)
    end

    it 'cleans and cuts the footer and name' do
      theme = described_class.new('footer' => "line\none\t#{'x' * 300}", 'name' => 'N' * 100)
      expect(theme.footer).not_to match(/[[:cntrl:]]/)
      expect(theme.footer.length).to eq(160)
      expect(theme.name.length).to eq(60)
    end

    it 'tolerates sections of the wrong type' do
      theme = described_class.new('colors' => 'blue', 'dark' => ['x'], 'categories' => %w[a b])
      expect(theme.light).to eq(described_class::DEFAULT_LIGHT)
      expect(theme.categories).to eq({})
      expect(theme.problems.size).to be >= 3
    end

    it 'logs each problem once, not on every chart' do
      expect(described_class).to receive(:warn).once
      2.times { described_class.new('colors' => { 'background' => 'red' }) }
    end
  end

  describe '#assign' do
    let(:theme) { described_class.new('series' => %w[#111111 #222222 #333333], 'categories' => { 'European' => '#abcdef' }) }

    it 'gives the series colours in order' do
      expect(theme.assign(%w[a b c])).to eq(%w[#111111 #222222 #333333])
    end

    it 'keeps a named category on its fixed colour wherever it appears, and does not reuse that colour' do
      expect(theme.assign(['A', 'european', 'B'])).to eq(%w[#111111 #abcdef #222222])
      expect(theme.assign(['European', 'x'])).to eq(%w[#abcdef #111111])
    end

    it 'ignores case and accents in category names' do
      accented = described_class.new('categories' => { 'Concesión' => '#abcdef' })
      expect(accented.assign(['CONCESION'])).to eq(['#abcdef'])
    end

    it 'wraps around when there are more labels than colours' do
      expect(theme.assign(%w[a b c d e])).to eq(%w[#111111 #222222 #333333 #111111 #222222])
    end

    it 'is stable: the same labels always get the same colours' do
      expect(theme.assign(%w[a b])).to eq(theme.assign(%w[a b]))
    end
  end

  describe 'colours on a dark page and text on a colour' do
    it 'lightens a colour that would vanish on dark and keeps one that is already light' do
      expect(described_class.for_dark('#007336')).not_to eq('#007336')
      expect(described_class.luminance(*described_class.rgb(described_class.for_dark('#007336')))).to be > 0.2
      expect(described_class.for_dark('#68af27')).to eq('#68af27')
      expect(described_class.for_dark('#fff')).to eq('#fff')
    end

    it 'reads three-digit colours' do
      expect(described_class.rgb('#0a0')).to eq([0, 170, 0])
    end

    it 'picks white text on a dark colour and near-black on a light one' do
      expect(described_class.ink('#007336')).to eq('#ffffff')
      expect(described_class.ink('#4c4c4c')).to eq('#ffffff')
      expect(described_class.ink('#68af27')).to eq('#1a1a1a')
      expect(described_class.ink('#c58b00')).to eq('#1a1a1a')
    end
  end
end

RSpec.describe Mcp::Widgets::Frame do
  let(:theme) { Mcp::Theme.new('footer' => 'Source: the test database') }
  let(:colours) { %w[#007336 #68af27] }

  it 'declares light and dark values for the page, each category colour and the text that reads on it' do
    css = described_class.css_vars(theme, colours)
    light, dark = css.split('@media')
    expect(light).to include('--bg:#ffffff', '--c0:#007336', '--k0:#ffffff', '--c1:#68af27', '--k1:#1a1a1a')
    expect(dark).to include('--bg:#161b22')
    expect(dark).not_to include('--c0:#007336') # the dark green is lightened on a dark page
  end

  it 'replaces every variable in a standalone picture by its light value' do
    svg = described_class.standalone(inner: '<rect style="fill:var(--c0)"/><text style="fill:var(--k0)">x</text>', width: 400, height: 100,
                                     title: 'T', words: described_class::WORDS['en'], rules: '.a{stroke:var(--grid)}', theme: theme, colours: colours)
    expect(svg).not_to include('var(')
    expect(svg).to include('fill:#007336', 'fill:#ffffff', 'stroke:#dfe5df')
    expect { REXML::Document.new(svg) }.not_to raise_error
  end

  it 'draws the caption lines and the theme footer into the picture, wrapped, and grows the picture for them' do
    words = described_class::WORDS['en']
    base = { inner: '', width: 400, height: 100, title: '', words: words, rules: '', theme: Mcp::Theme.new({}), colours: [] }
    plain = described_class.standalone(**base)
    noted = described_class.standalone(**base.merge(theme: theme, notes: ["#{'word ' * 60}end"]))
    expect(noted).to include('Source: the test database')
    expect(noted.scan('class="note"').size).to be >= 3
    expect(noted[/height="(\d+)"/, 1].to_i).to be > plain[/height="(\d+)"/, 1].to_i
  end

  it 'shows the same notes on the page, escaped' do
    html = described_class.html_page(inner: '', width: 400, height: 100, title: 'T', words: described_class::WORDS['en'], language: 'en', svg: '<svg/>',
                                     rules: '', theme: theme, colours: [], notes: ['a <b> & c'])
    expect(html).to include('<p class="note">a &lt;b&gt; &amp; c</p>', '<p class="note">Source: the test database</p>')
  end

  it 'wraps text at word boundaries and copes with a very long word' do
    lines = described_class.wrap('alpha beta gamma delta', 11)
    expect(lines).to eq(['alpha beta', 'gamma delta'])
    expect(described_class.wrap('x' * 30, 10)).to eq(['x' * 30])
    expect(described_class.wrap('', 10)).to eq([])
  end

  it 'names a download after the title, with a plain-letters fallback' do
    expect(described_class.file_name('Álvarez, Olga!', { file: 'chart' }, 'png')).to eq('alvarez-olga.png')
    expect(described_class.file_name('¿?', { file: 'chart' })).to eq('chart.svg')
  end
end

RSpec.describe Mcp::Widgets::Timeline, 'with a theme' do
  let(:rows) do
    [{ 'lane' => 'Funding', 'label' => 'A', 'start' => '2026-01-01', 'end' => '2026-06-01' },
     { 'lane' => 'Papers', 'label' => 'B', 'start' => '2026-03-01' }]
  end

  def drawn(theme)
    described_class.render(rows: rows, title: 'T', today: Date.new(2026, 10, 8), theme: theme)
  end

  it 'draws lanes in the theme colours, in order' do
    svg = drawn(Mcp::Theme.new('series' => %w[#111111 #222222]))[:svg]
    expect(svg).to include('fill:#111111', 'fill:#222222')
  end

  it 'keeps a named lane on its fixed colour' do
    svg = drawn(Mcp::Theme.new('series' => %w[#111111 #222222], 'categories' => { 'papers' => '#abcdef' }))[:svg]
    expect(svg).to include('fill:#abcdef')
  end

  it 'takes the page colours, the font and the footer from the theme' do
    theme = Mcp::Theme.new('colors' => { 'background' => '#fafafa', 'highlight' => '#00ff00' }, 'font' => 'Georgia, serif', 'footer' => 'Our footer')
    out = drawn(theme)
    expect(out[:svg]).to include('#fafafa', 'font-family:Georgia, serif', 'Our footer')
    expect(out[:svg]).to include('stroke:#00ff00') # the today line
    expect(out[:html]).to include('<p class="note">Our footer</p>', '--hl:#00ff00')
  end

  it 'uses the deployment theme file when no theme is passed' do
    ENV['CBGP_THEME_FILE'] = File.join(Dir.tmpdir, 'cbgp-timeline-theme-spec.yml')
    File.write(ENV['CBGP_THEME_FILE'], "series: ['#0a0b0c', '#0d0e0f']\n")
    Mcp::Theme.reset!
    out = described_class.render(rows: rows, today: Date.new(2026, 10, 8))
    expect(out[:svg]).to include('fill:#0a0b0c')
  ensure
    File.delete(ENV['CBGP_THEME_FILE']) if File.exist?(ENV['CBGP_THEME_FILE'].to_s)
    ENV['CBGP_THEME_FILE'] = File.join(__dir__, '..', 'fixtures', 'no-such-theme.yml')
    Mcp::Theme.reset!
  end

  it 'puts dark text on a light bar and white text on a dark bar, for in-bar labels' do
    long = [{ 'label' => 'A label that has to sit inside its own long bar to be readable', 'start' => '2020-01-01', 'end' => '2026-09-01' },
            { 'lane' => 'B', 'label' => 'x', 'start' => '2026-09-02' }]
    out = described_class.render(rows: long, today: Date.new(2026, 10, 8), theme: Mcp::Theme.new('series' => %w[#007336 #68af27]))
    expect(out[:svg]).to match(/class="lbl inbar"[^>]*style="fill:#ffffff"/) # white on CBGP green
    light_bar = described_class.render(rows: long, today: Date.new(2026, 10, 8), theme: Mcp::Theme.new('series' => %w[#68af27 #007336]))
    expect(light_bar[:svg]).to match(/class="lbl inbar"[^>]*style="fill:#1a1a1a"/) # near-black on leaf green
  end
end
