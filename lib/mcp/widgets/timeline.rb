# frozen_string_literal: true

require 'cgi'
require 'date'
require_relative '../tool'
require_relative 'frame'

module Mcp
  module Widgets
    # A self-contained HTML/SVG timeline (no scripts, no external files) for
    # rows of { label, start, end, lane }. It knows nothing about what the
    # rows mean: any tool's output that can be put into that shape can be
    # drawn. Lanes are horizontal bands (in order of first appearance); a row
    # with an end date is a bar, one without is a point - unless it is marked
    # ongoing, when the bar runs to today.
    module Timeline
      MAX_ROWS = 150
      WIDTH = 960.0
      LEFT = 200.0 # lane-name gutter: fits "Compromiso de financiación" (26 characters) at 11px bold
      RIGHT = 24.0
      ROW_H = 24
      LANE_MAX = 26
      CHAR_W = 6.4
      LANE_GAP = 26
      AXIS_H = 34
      WORDS = {
        'en' => Frame::WORDS['en'].merge(ongoing: 'ongoing', today: 'Today', title: 'Timeline', file: 'timeline',
                                         months: %w[Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec]),
        'es' => Frame::WORDS['es'].merge(ongoing: 'en curso', today: 'Hoy', title: 'Cronología', file: 'cronologia',
                                         months: %w[ene feb mar abr may jun jul ago sep oct nov dic])
      }.freeze
      TITLE_H = Frame::TITLE_H
      # This picture's own style rules; colours come from the theme through CSS variables (see Frame).
      RULES = <<~CSS.freeze
        .band{fill:var(--band)}.grid{stroke:var(--grid);stroke-width:1}.axis{stroke:var(--muted);stroke-width:1}
        .today{stroke:var(--hl);stroke-width:1.5;stroke-dasharray:4 3}
        .todaylbl{fill:var(--hl);font-size:11px;font-weight:600}.tick{fill:var(--muted);font-size:11px}.lane{font-size:11px;font-weight:600}.lbl{fill:var(--fg);font-size:12px}
      CSS

      Row = Struct.new(:label, :start, :end_date, :lane, :detail, :ongoing, :point, keyword_init: true)

      module_function

      # One drawing, three outputs: +html+ (the page: responsive, follows the viewer's dark mode, with
      # download links), +svg+ (a self-contained light-theme file: literal colours, its own styles, a
      # background and the title drawn in - what the download link carries and what the PNG is made from).
      # Colours, font and footer come from the theme (Mcp::Theme), by default the deployment's theme file.
      #
      # @return [Hash] { html:, svg:, rows:, from:, to:, lanes: }
      def render(rows:, title: nil, today: Date.today, language: 'en', theme: Theme.current)
        parsed = parse_rows(rows, today)
        from = parsed.map(&:start).min
        to = parsed.map { |r| r.end_date || r.start }.max
        from, to = pad(from, to)
        lanes = parsed.map(&:lane).uniq
        language = WORDS.key?(language) ? language : 'en'
        words = WORDS[language]
        colours = theme.assign(lanes)
        drawing = chart(parsed, lanes, from, to, today, words)
        frame = { inner: drawing[:inner], width: WIDTH, height: drawing[:height], title: title.to_s, words: words,
                  rules: RULES, theme: theme, colours: colours }
        svg = Frame.standalone(**frame)
        { html: Frame.html_page(**frame, language: language, svg: svg), svg: svg, rows: parsed.size,
          from: from.iso8601, to: to.iso8601, lanes: lanes }
      end

      def parse_rows(rows, today)
        raise ToolError, 'rows must be a non-empty list of {label, start, end, lane}.' unless rows.is_a?(Array) && !rows.empty?
        raise ToolError, "At most #{MAX_ROWS} rows can be drawn; filter first (got #{rows.size})." if rows.size > MAX_ROWS

        rows.each_with_index.map do |row, i|
          raise ToolError, "Row #{i + 1} must be an object with label and start." unless row.is_a?(Hash)

          label = row['label'].to_s.strip
          raise ToolError, "Row #{i + 1} has no label." if label.empty?

          start = parse_date(row['start'], "row #{i + 1} start", today)
          raise ToolError, "Row #{i + 1} (#{label}) has no valid start date." unless start

          finish = blank?(row['end']) ? nil : parse_date(row['end'], "row #{i + 1} end", today)
          raise ToolError, "Row #{i + 1} (#{label}): end is before start." if finish && finish < start

          ongoing = row['ongoing'] == true && finish.nil?
          # An ongoing row runs to today - or, if it has not started yet, begins at its start.
          Row.new(label: label, start: start, end_date: ongoing ? [today, start].max : finish,
                  lane: row['lane'].to_s.strip.then { |l| l.empty? ? 'Events' : l },
                  detail: row['detail'].to_s.strip, ongoing: ongoing, point: finish.nil? && !ongoing)
        end
      end

      def blank?(value)
        value.nil? || value.to_s.strip.empty?
      end

      def parse_date(value, where, today)
        text = value.to_s.strip
        return today if text.casecmp?('today') || text.casecmp?('hoy')

        Date.iso8601(text[0, 10])
      rescue ArgumentError
        raise ToolError, "#{where}: '#{text}' is not a date. Use YYYY-MM-DD (a full timestamp is also accepted) or today."
      end

      def pad(from, to)
        return [from - 15, to + 15] if from == to

        margin = [((to - from) * 0.02).ceil, 1].max
        [from - margin, to + margin]
      end

      # The chart's shapes, without the <svg> wrapper: { inner:, height: }.
      def chart(rows, lanes, from, to, today, words)
        span = (to - from).to_f
        x = ->(date) { LEFT + ((date - from).to_f / span) * (WIDTH - LEFT - RIGHT) }
        y = AXIS_H
        bands = +''
        body = +''
        lanes.each_with_index do |lane, li|
          color = Frame.colour(li)
          lane_rows = rows.select { |r| r.lane == lane }
          height = lane_rows.size * ROW_H
          bands << %(<rect class="band" x="0" y="#{y}" width="#{WIDTH}" height="#{height + 6}"/>)
          body << %(<text class="lane" x="8" y="#{y + 17}" style="fill:#{color}">#{esc(clip(lane, LANE_MAX))}</text>)
          lane_rows.each_with_index do |row, i|
            body << row_svg(row, x, y + 3 + i * ROW_H, li, words)
          end
          y += height + 6 + LANE_GAP / 2
        end
        plot_bottom = y + 10
        today_visible = today.between?(from, to)
        total_h = plot_bottom + (today_visible ? 14 : 0) # room under the chart for the "Today" label
        axis = axis_svg(from, to, x, plot_bottom, words)
        marker = today_visible ? today_marker(x.(today), plot_bottom, words[:today]) : ''
        { inner: "#{bands}#{axis}#{marker}#{body}", height: total_h }
      end

      # The dashed vertical line for today, labelled so it explains itself;
      # the label sits under the chart and flips to the left near the right edge.
      def today_marker(pos, plot_bottom, word)
        anchor = pos > WIDTH - 60 ? 'end' : 'middle'
        %(<line class="today" x1="#{n(pos)}" x2="#{n(pos)}" y1="#{AXIS_H - 4}" y2="#{plot_bottom - 6}"/>) +
          %(<text class="todaylbl" x="#{n(pos)}" y="#{plot_bottom + 6}" text-anchor="#{anchor}">#{esc(word)}</text>)
      end

      def row_svg(row, x, top, lane_index, words)
        color = Frame.colour(lane_index)
        mid = top + ROW_H / 2.0 - 2
        tip = esc([row.label, "#{row.start.iso8601}#{row.point ? '' : " → #{row.ongoing ? words[:ongoing] : row.end_date.iso8601}"}", row.detail].reject(&:empty?).join("\n"))
        x1 = x.(row.start)
        if row.point
          shape = %(<polygon points="#{n(x1)},#{n(mid - 6)} #{n(x1 + 6)},#{n(mid)} #{n(x1)},#{n(mid + 6)} #{n(x1 - 6)},#{n(mid)}" style="fill:#{color}"/>)
          right_x = x1 + 10
          left_x = x1 - 10
          bar_w = 0
        else
          x2 = [x.(row.end_date), x1 + 3].max
          shape = %(<rect x="#{n(x1)}" y="#{n(mid - 6)}" width="#{n(x2 - x1)}" height="12" rx="3" style="fill:#{color}" opacity=".85"/>)
          shape += %(<path d="M#{n(x2)} #{n(mid - 6)} l8 6 l-8 6z" style="fill:#{color}"/>) if row.ongoing
          right_x = x2 + (row.ongoing ? 12 : 6)
          left_x = x1 - 6
          bar_w = x2 - x1
        end
        label_x, anchor, css_class, text = place_label(row.label, right_x, left_x, x1, bar_w)
        ink = css_class.include?('inbar') ? %( style="fill:#{Frame.ink(lane_index)}") : ''
        %(<g><title>#{tip}</title>#{shape}<text class="#{css_class}" x="#{n(label_x)}" y="#{n(mid + 4)}" text-anchor="#{anchor}"#{ink}>#{esc(text)}</text></g>)
      end

      # Where a row's label goes, so it is always readable and never runs into
      # the lane names or off the picture: right of the mark if it fits, else
      # left of it, else inside a long bar, else cut short on the roomier
      # side. (The hover text always carries the full label.)
      def place_label(label, right_x, left_x, bar_start, bar_w)
        text = clip(label, 48)
        width = text.length * CHAR_W
        right_room = WIDTH - RIGHT - right_x
        left_room = left_x - (LEFT + 4)
        if width <= right_room then [right_x, 'start', 'lbl', text]
        elsif width <= left_room then [left_x, 'end', 'lbl', text]
        elsif bar_w >= 120 then [bar_start + 6, 'start', 'lbl inbar', clip_to(text, bar_w - 12)]
        elsif right_room >= left_room then [right_x, 'start', 'lbl', clip_to(text, right_room)]
        else [left_x, 'end', 'lbl', clip_to(text, left_room)]
        end
      end

      def clip_to(text, pixels)
        fit = [(pixels / CHAR_W).floor, 4].max
        text.length <= fit ? text : "#{text[0, fit - 1]}…"
      end

      def axis_svg(from, to, x, total_h, words)
        ticks = +''
        if (to - from) > 800
          (from.year + 1..to.year).each { |yr| ticks << tick(x.(Date.new(yr, 1, 1)), yr.to_s, total_h) }
        else
          cursor = Date.new(from.year, from.month, 1) >> 1
          step = (to - from) > 300 ? 3 : 1
          while cursor <= to
            ticks << tick(x.(cursor), cursor.month == 1 ? cursor.year.to_s : words[:months][cursor.month - 1], total_h)
            cursor >>= step
          end
        end
        %(<line class="axis" x1="#{LEFT}" x2="#{WIDTH - RIGHT}" y1="#{AXIS_H - 8}" y2="#{AXIS_H - 8}"/>#{ticks})
      end

      def tick(pos, text, total_h)
        %(<line class="grid" x1="#{n(pos)}" x2="#{n(pos)}" y1="#{AXIS_H - 8}" y2="#{total_h - 6}"/><text class="tick" x="#{n(pos)}" y="#{AXIS_H - 14}" text-anchor="middle">#{esc(text)}</text>)
      end

      def clip(text, max)
        text.length > max ? "#{text[0, max - 1]}…" : text
      end

      def esc(text)
        Frame.esc(text)
      end

      def n(value)
        Frame.n(value)
      end
    end
  end
end
