# frozen_string_literal: true

require 'yaml'

module Mcp
  # How charts look: colours, font, a footer line. Read from a small YAML file
  # that a deployment mounts into the container and edits freely (default
  # theme/theme.yml next to the application, or the path in CBGP_THEME_FILE), so
  # branding is a deployment setting, never code and never the ontology.
  #
  # The file is read again whenever it changes, so an edit shows in the next
  # chart without a restart. Anything missing or invalid falls back to the
  # built-in default for THAT key (and is logged once): a typo in a colour must
  # never stop a chart from being drawn. Every value that ends up in an SVG or a
  # style rule is validated first - a colour must be #rgb or #rrggbb, a font a
  # plain list of family names - so the file cannot inject markup.
  class Theme
    DEFAULT_PATH = File.expand_path('../../theme/theme.yml', __dir__)
    COLOUR = /\A#(?:\h{3}|\h{6})\z/
    FONT_LIST = /\A[\w\s,'"\-.]{1,120}\z/
    MAX_SERIES = 24

    LIGHT_KEYS = { 'bg' => 'background', 'fg' => 'text', 'muted' => 'muted', 'band' => 'band', 'grid' => 'grid', 'hl' => 'highlight' }.freeze
    DEFAULT_LIGHT = { 'bg' => '#ffffff', 'fg' => '#262626', 'muted' => '#666666', 'band' => '#f2f5f2', 'grid' => '#dfe5df', 'hl' => '#c0392b' }.freeze
    DEFAULT_DARK = { 'bg' => '#161b22', 'fg' => '#e6e9ee', 'muted' => '#9aa4b2', 'band' => '#1e252e', 'grid' => '#2c3542', 'hl' => '#ff7b6b' }.freeze
    # CBGP look. The first, fourth and fifth colours are sampled from the CBGP logo (leaf green #007336,
    # leaf green #68af27, lettering charcoal #4c4c4c); amber, blue and the rest are chosen to stay apart
    # from the greens and from each other (including for colour-blind readers), since eight categories
    # cannot all be green.
    DEFAULT_SERIES = %w[#007336 #c58b00 #2a78b5 #68af27 #4c4c4c #b5532a #8a5ab5 #2a9fa6].freeze
    DEFAULT_FONT = 'Calibri, Carlito, "DejaVu Sans", Arial, sans-serif'

    attr_reader :name, :font, :light, :dark, :series, :categories, :footer, :problems

    @mutex = Mutex.new
    @cached = nil
    @warned = {}

    class << self
      def path
        configured = ENV['CBGP_THEME_FILE'].to_s.strip
        configured.empty? ? DEFAULT_PATH : configured
      end

      # The theme to draw with now. Cheap: one stat call, parsing only when the file changed.
      def current
        file = path
        stamp = [file, (File.mtime(file) if File.file?(file))]
        @mutex.synchronize { return @cached[1] if @cached && @cached[0] == stamp }
        theme = stamp[1] ? load_file(file) : default
        @mutex.synchronize { @cached = [stamp, theme] }
        theme
      end

      def default
        new({})
      end

      def reset!
        @mutex.synchronize do
          @cached = nil
          @warned = {}
        end
      end

      # Logs a problem once per (file, message), not on every chart.
      def warn_once(message)
        @mutex.synchronize do
          return if @warned[message]

          @warned[message] = true
        end
        warn "[MCP] theme: #{message}"
      end

      # A colour shown on a dark page: kept if it is already light enough to stand out from a dark
      # background (about 3:1 contrast), otherwise mixed toward white so a dark brand green does not vanish.
      def for_dark(hex)
        r, g, b = rgb(hex)
        return hex if luminance(r, g, b) >= 0.18

        mix = ->(c) { (c + (255 - c) * 0.55).round }
        format('#%02x%02x%02x', mix.(r), mix.(g), mix.(b))
      end

      INK_LIGHT = '#ffffff'
      INK_DARK = '#1a1a1a'

      # The text colour that reads on top of +hex+: whichever of white and near-black has the higher
      # contrast ratio against it (the WCAG measure), so leaf green gets dark text and CBGP green white.
      def ink(hex)
        l = luminance(*rgb(hex))
        contrast = ->(other) { ((l + 0.05) / (other + 0.05)).then { |r| r < 1 ? 1 / r : r } }
        contrast.(luminance(*rgb(INK_LIGHT))) >= contrast.(luminance(*rgb(INK_DARK))) ? INK_LIGHT : INK_DARK
      end

      def luminance(r, g, b)
        lin = ->(c) { c /= 255.0; c <= 0.03928 ? c / 12.92 : ((c + 0.055) / 1.055)**2.4 }
        (0.2126 * lin.(r)) + (0.7152 * lin.(g)) + (0.0722 * lin.(b))
      end

      def rgb(hex)
        digits = hex.delete('#')
        digits = digits.chars.map { |c| c * 2 }.join if digits.length == 3
        digits.scan(/../).map { |pair| pair.to_i(16) }
      end

      private

      def load_file(file)
        data = YAML.safe_load(File.read(file), permitted_classes: [], aliases: false)
        unless data.is_a?(Hash)
          warn_once("#{file} is not a YAML mapping; using the built-in theme")
          return default
        end
        new(data)
      rescue StandardError => e
        warn_once("#{file} could not be read (#{e.class}); using the built-in theme")
        default
      end
    end

    def initialize(data)
      @problems = []
      data = {} unless data.is_a?(Hash)
      colors = hash_of(data['colors'], 'colors')
      dark_in = hash_of(data['dark'], 'dark')
      @name = text(data['name'], 60) || 'default'
      @font = font_from(data['font'])
      @light = LIGHT_KEYS.to_h { |key, label| [key, colour(colors[label], "colors.#{label}") || DEFAULT_LIGHT[key]] }
      @dark = LIGHT_KEYS.to_h { |key, label| [key, colour(dark_in[label], "dark.#{label}") || DEFAULT_DARK[key]] }
      @series = series_from(data['series'])
      @categories = categories_from(data['categories'])
      @footer = text(data['footer'], 160)
      @problems.each { |p| self.class.warn_once(p) }
    end

    # One colour per label, in order: a label named under categories keeps its fixed
    # colour wherever it appears; the others take the series colours in order, so a
    # chart is the same every time it is drawn from the same data.
    #
    # @return [Array<String>] hex colours, one per label
    def assign(labels)
      fixed = labels.map { |l| @categories[Theme.key(l)] }
      free = @series.dup
      taken = fixed.compact
      free = free.reject { |c| taken.include?(c) } if free.size > taken.size
      next_free = 0
      labels.each_index.map do |i|
        fixed[i] || begin
          colour = free[next_free % free.size]
          next_free += 1
          colour
        end
      end
    end

    def self.key(label)
      label.to_s.unicode_normalize(:nfd).gsub(/\p{Mn}/, '').downcase.strip
    end

    private

    def hash_of(value, where)
      return {} if value.nil?
      return value if value.is_a?(Hash)

      @problems << "#{where} must be a mapping; ignored"
      {}
    end

    def text(value, max)
      return nil if value.nil?

      cleaned = value.to_s.gsub(/[[:cntrl:]]/, ' ').strip
      cleaned.empty? ? nil : cleaned[0, max]
    end

    def colour(value, where)
      return nil if value.nil?

      text = value.to_s.strip
      return text.downcase if text.match?(COLOUR)

      @problems << "#{where} (#{text[0, 20].inspect}) is not a colour like #1a2b3c; using the default"
      nil
    end

    def font_from(value)
      return DEFAULT_FONT if value.nil?

      text = value.to_s.strip
      return text if text.match?(FONT_LIST)

      @problems << 'font must be a plain list of font names; using the default'
      DEFAULT_FONT
    end

    def series_from(value)
      return DEFAULT_SERIES if value.nil?
      return (@problems << 'series must be a list of colours; using the default') && DEFAULT_SERIES unless value.is_a?(Array)

      good = value.first(MAX_SERIES).each_with_index.filter_map { |c, i| colour(c, "series[#{i}]") }
      if good.size < 2
        @problems << 'series needs at least two valid colours; using the default'
        return DEFAULT_SERIES
      end
      good
    end

    def categories_from(value)
      return {} if value.nil?
      return (@problems << 'categories must be a mapping of name to colour; ignored') && {} unless value.is_a?(Hash)

      value.each_with_object({}) do |(name, hex), out|
        valid = colour(hex, "categories.#{name.to_s[0, 30]}")
        out[Theme.key(name)] = valid if valid && !name.to_s.strip.empty?
      end
    end
  end
end
