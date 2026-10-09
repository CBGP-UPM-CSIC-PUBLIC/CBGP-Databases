# frozen_string_literal: true

require_relative '../tool'
require_relative 'frame'

module Mcp
  module Widgets
    # Bar, stacked, 100% stacked, line and area charts from one tidy table, in the deployment's theme. It knows
    # nothing about what the numbers mean: a table is x positions (years, categories) and one or more series.
    #
    # Every chart comes in two shapes from the same data - a wide slide (16:9) and a report column (3:2) - sized
    # so the finished image, title and caption included, has exactly that proportion; the one asked for is
    # shown, the other is offered as a download. Colours come from the theme: a series takes its category's
    # fixed colour if the theme names one, else the next series colour, so the same data always looks the same.
    module Chart
      STYLES = %w[bar stacked percent line area].freeze
      SHAPES = { 'slide' => [960, 540], 'report' => [720, 480] }.freeze
      MAX_SERIES = 12
      MAX_POINTS = 120

      WORDS = {
        'en' => Frame::WORDS['en'].merge(none: '(none)', other: 'Other', slide: 'slide 16:9', report: 'report 3:2', total: 'Total', category: 'Category', decimal: '.', group: ',', year: 'Year', records: 'Records', total_of: 'Total', count_of: 'Count of', records_noun: 'records', sum_of: 'Total of', by: 'by', data_as_of: 'Data as of', records_read: 'records read',
                                         left_out: 'Left out for lacking a needed field', partial_year: 'The current year (%{year}) is counted as of today, not as of 31 December.',
                                         mode_by_date: 'by the year of a date', mode_active_at_end: 'on the books at the end of each year', mode_active_during: 'present at any time in each year',
                                         mode_spread: 'amounts shared across the years in proportion to days',
                                         k: ' k', m: ' M'),
        'es' => Frame::WORDS['es'].merge(none: '(sin valor)', other: 'Otros', slide: 'diapositiva 16:9', report: 'informe 3:2', total: 'Total', category: 'Categoría', decimal: ',', group: '.', year: 'Año', records: 'Registros', total_of: 'Total', count_of: 'Número de', records_noun: 'registros de', sum_of: 'Total de', by: 'por', data_as_of: 'Datos a fecha', records_read: 'registros leídos',
                                         left_out: 'Excluidos por faltar un dato necesario', partial_year: 'El año en curso (%{year}) se cuenta a fecha de hoy, no a 31 de diciembre.',
                                         mode_by_date: 'según el año de una fecha', mode_active_at_end: 'en plantilla a final de cada año', mode_active_during: 'presentes en algún momento de cada año',
                                         mode_spread: 'importes repartidos entre los años en proporción a los días',
                                         k: ' mil', m: ' M')
      }.freeze

      RULES = <<~CSS.freeze
        .grid{stroke:var(--grid);stroke-width:1}.axis{stroke:var(--muted);stroke-width:1}
        .tick{fill:var(--muted);font-size:11px}.xl{fill:var(--fg);font-size:11px}.val{fill:var(--fg);font-size:10px}
        .tot{fill:var(--fg);font-size:10px;font-weight:600}.leg{fill:var(--fg);font-size:11px}.ylab{fill:var(--muted);font-size:11px}
      CSS

      Table = Struct.new(:x_labels, :series, keyword_init: true) # series: [{ label:, values: [Float] }]

      module_function

      # @param table [Table]
      # @return [Hash] { html:, svg:, variants: [{ svg:, label: }], tsv:, shape: }
      def render(table:, style:, shape: 'slide', title: nil, y_label: nil, x_title: nil, language: 'en', theme: Theme.current, notes: [])
        raise ToolError, "style must be one of: #{STYLES.join(', ')}." unless STYLES.include?(style)
        raise ToolError, "shape must be one of: #{SHAPES.keys.join(', ')}." unless SHAPES.key?(shape)
        raise ToolError, 'There is nothing to chart: no values came back. Check the form, where and fields (and "excluded" in the numbers).' if table.series.empty? || table.x_labels.empty?
        raise ToolError, "Too many points to chart legibly (#{table.x_labels.size}); narrow it with from/to or where." if table.x_labels.size > MAX_POINTS

        language = WORDS.key?(language) ? language : 'en'
        words = WORDS[language]
        colours = theme.assign(table.series.map { |s| s[:label] })
        pictures = [shape, *(SHAPES.keys - [shape])].map do |name|
          [name, picture(table, style, name, title.to_s, y_label, words, language, theme, colours, notes)]
        end.to_h
        primary = pictures[shape]
        variants = pictures.except(shape).map { |name, p| { svg: p[:svg], label: words[name.to_sym] } }
        frame = primary[:frame].merge(language: language, svg: primary[:svg], variants: variants, data: tsv(table, x_title || words[:category], language))
        { html: Frame.html_page(**frame), svg: primary[:svg], variants: variants, tsv: frame[:data], shape: shape }
      end

      # .f0 fills with series 0's colour, .s0 strokes a line in it, .k0 is the text colour that reads on it: written
      # once here instead of in every shape.
      def series_rules(count)
        count.times.map do |i|
          ".f#{i}{fill:var(--c#{i})}.s#{i}{fill:none;stroke:var(--c#{i});stroke-width:2.5;stroke-linejoin:round}.k#{i}{fill:var(--k#{i})}"
        end.join("\n") + "\n"
      end

      def picture(table, style, shape, title, y_label, words, language, theme, colours, notes)
        w, target = SHAPES[shape]
        top = title.empty? ? 0 : Frame::TITLE_H
        h = target - top - Frame.notes_height(theme, notes, w) - 4
        inner = draw(table, style, w, h, y_label, words, language)
        frame = { inner: inner, width: w, height: h, title: title, words: words, rules: RULES + series_rules(table.series.size), theme: theme, colours: colours, notes: notes }
        { svg: Frame.standalone(**frame), frame: frame }
      end

      # --- the table ----------------------------------------------------------------------------

      # A table from aggregation rows ({period, group, label, value}). With periods they are the x axis and the
      # groups the series; without, the (first) group is the x axis and the second, if any, the series. At most
      # +top_n+ series are kept, the smallest joining one "Other".
      def table_from_rows(rows, top_n: 8, words: WORDS['en'], single_label: 'Value', max_x: nil)
        has_period = rows.any? { |r| r[:period] }
        cells = rows.map do |r|
          groups = Array(r[:label] || r[:group])
          groups = groups.map { |g| g == '(none)' ? words[:none] : g }
          x, name = if has_period then [r[:period], groups.join(' / ')] else [groups[0] || single_label, groups[1]] end
          [x.to_s, (name || single_label), r[:value].to_f]
        end
        x_labels = cells.map(&:first).uniq.sort_by { |x| x =~ /\A\d+\z/ ? [0, x.to_i, ''] : [1, 0, x] }
        by_series = cells.group_by { |c| c[1] }
        series = by_series.map do |label, items|
          sums = items.group_by(&:first).transform_values { |v| v.sum { |c| c[2] } }
          { label: label, values: x_labels.map { |x| sums.fetch(x, 0.0) } }
        end
        table = Table.new(x_labels: x_labels, series: order(series, words, top_n, x_labels.size))
        has_period ? table : by_size(table, words, max_x)
      end

      # Categories on the x axis (no years): biggest first, "Other" then "(none)" last, and at most max_x of
      # them, the smallest merged into "Other".
      def by_size(table, words, max_x)
        totals = table.x_labels.each_index.map { |i| table.series.sum { |s| s[:values][i] } }
        special = [words[:other], words[:none]]
        order = table.x_labels.each_index.sort_by { |i| [special.index(table.x_labels[i]) || -1, -totals[i], table.x_labels[i]] }
        if max_x && order.size > max_x
          keep = order.reject { |i| special.include?(table.x_labels[i]) }.first([max_x - 1, 1].max)
          tail = order - keep
          none = tail.select { |i| table.x_labels[i] == words[:none] }
          merged = tail - none
          labels = keep.map { |i| table.x_labels[i] } + [words[:other]] + none.map { |i| table.x_labels[i] }
          series = table.series.map do |s|
            { label: s[:label], values: keep.map { |i| s[:values][i] } + [merged.sum { |i| s[:values][i] }] + none.map { |i| s[:values][i] } }
          end
          return Table.new(x_labels: labels, series: series)
        end
        Table.new(x_labels: order.map { |i| table.x_labels[i] }, series: table.series.map { |s| { label: s[:label], values: order.map { |i| s[:values][i] } } })
      end

      # Biggest series first, then "Other", then "(none)"; at most top_n series, the smallest joining "Other".
      def order(series, words, top_n, points)
        weight = ->(s) { s[:values].sum }
        none = series.find { |s| s[:label] == words[:none] }
        other = series.find { |s| s[:label] == words[:other] }
        main = series.reject { |s| s.equal?(none) || s.equal?(other) }.sort_by { |s| [-weight.(s), s[:label]] }
        room = top_n - (none ? 1 : 0)
        if main.size + (other ? 1 : 0) > room
          keep = main.first([room - 1, 1].max)
          merged = { label: words[:other], values: Array.new(points, 0.0) }
          (main.drop(keep.size) + [other].compact).each { |s| s[:values].each_with_index { |v, i| merged[:values][i] += v } }
          main = keep
          other = merged
        end
        (main + [other, none].compact).first(MAX_SERIES)
      end

      def tsv(table, x_title, language)
        words = WORDS[language]
        lines = [([x_title] + table.series.map { |s| s[:label] }).join("\t")]
        table.x_labels.each_with_index do |x, i|
          lines << ([x] + table.series.map { |s| plain(s[:values][i], words) }).join("\t")
        end
        "#{lines.join("\n")}\n"
      end

      # --- numbers ----------------------------------------------------------------------------

      def plain(value, words)
        v = value.to_f
        text = (v - v.round).abs < 0.005 ? v.round.to_s : format('%.2f', v).sub(/0+\z/, '')
        text.sub('.', words[:decimal])
      end

      # 1234567 -> "1.2 M", 12500 -> "12.5 k", 1234 -> "1,234" (Spanish: "1,2 M", "12,5 mil", "1.234").
      def fmt(value, words, compact: false)
        v = value.to_f
        a = v.abs
        return "#{trim(v / 1_000_000.0, words)}#{words[:m]}" if compact && a >= 1_000_000
        return "#{trim(v / 1000.0, words)}#{words[:k]}" if compact && a >= 10_000
        return grouped(v.round, words) if a >= 1000

        plain(v, words)
      end

      def grouped(int, words)
        sign = int.negative? ? '-' : ''
        "#{sign}#{int.abs.to_s.reverse.scan(/\d{1,3}/).join(words[:group]).reverse}"
      end

      def trim(value, words)
        format('%.1f', value).sub(/\.0\z/, '').sub('.', words[:decimal])
      end

      # About five round tick values from 0 up to the first one at or above max.
      def nice_ticks(max)
        return [0, 1] unless max.to_f.positive?

        raw = max.to_f / 5
        magnitude = 10.0**Math.log10(raw).floor
        step = [1, 2, 2.5, 5, 10].map { |m| m * magnitude }.find { |s| s >= raw }
        (0..(max.to_f / step).ceil).map { |i| (i * step).round(6) }
      end

      # --- drawing ----------------------------------------------------------------------------

      def draw(table, style, w, h, y_label, words, language)
        series = table.series
        n = table.x_labels.size
        k = series.size
        stacked = %w[stacked percent area].include?(style)
        totals = n.times.map { |i| series.sum { |s| s[:values][i] } }
        shown = if style == 'percent'
                  series.map { |s| s[:values].each_with_index.map { |v, i| totals[i].positive? ? v * 100.0 / totals[i] : 0.0 } }
                else
                  series.map { |s| s[:values] }
                end
        peak = style == 'percent' ? 100 : (stacked ? totals.max : shown.flatten.max)
        ticks = nice_ticks(peak)
        tick_text = ticks.map { |t| style == 'percent' ? "#{plain(t, words)} %" : fmt(t, words, compact: true) }
        left = [(tick_text.map(&:length).max * 6.6) + 16, 40].max
        right = 14
        legend = legend_layout(series, left, w - right) if k > 1
        top = 8 + (y_label ? 16 : 0) + (legend ? legend[:height] + 4 : 0) + 6
        slant = slanted?(table.x_labels, (w - left - right).to_f / n)
        bottom = 28 + (slant ? [(table.x_labels.map { |l| [l.length, MAX_LABEL].min }.max * 4.2).ceil, 70].min : 0)
        plot_w = w - left - right
        plot_h = h - top - bottom
        band = plot_w.to_f / n
        y = ->(v) { top + plot_h - ((v.to_f / ticks.last) * plot_h) }
        ctx = { left: left, top: top, plot_h: plot_h, band: band, y: y, n: n, k: k, words: words, labels: table.x_labels, series: series, shown: shown, totals: totals, style: style }

        parts = []
        parts << grid(ticks, tick_text, left, w - right, y)
        parts << body(ctx)
        parts << x_axis(table.x_labels, left, top + plot_h, band, slant)
        parts << %(<text class="ylab" x="#{Frame.n(left)}" y="18">#{Frame.esc(y_label)}</text>) if y_label
        parts << legend_svg(series, legend, left, 8 + (y_label ? 16 : 0)) if legend
        parts.join
      end

      def grid(ticks, tick_text, x1, x2, y)
        ticks.each_with_index.map do |t, i|
          line = %(<line class="#{t.zero? ? 'axis' : 'grid'}" x1="#{Frame.n(x1)}" x2="#{Frame.n(x2)}" y1="#{Frame.n(y.(t))}" y2="#{Frame.n(y.(t))}"/>)
          line + %(<text class="tick" x="#{Frame.n(x1 - 6)}" y="#{Frame.n(y.(t) + 4)}" text-anchor="end">#{Frame.esc(tick_text[i])}</text>)
        end.join
      end

      MAX_LABEL = 18

      # Category names that do not fit side by side are set at a slant so EVERY bar keeps its name; a run of
      # years is thinned instead (every other year is still readable).
      def slanted?(labels, band)
        return false if labels.all? { |l| l.match?(/\A\d+\z/) }

        labels.map { |l| [l.length, MAX_LABEL].min }.max * 6.4 + 6 > band
      end

      def x_axis(labels, left, base, band, slant)
        widest = labels.map { |l| [l.length, MAX_LABEL].min }.max * 6.4 + 8
        step = slant ? 1 : [(widest / band).ceil, 1].max
        labels.each_with_index.filter_map do |label, i|
          next unless (i % step).zero?

          shown = label.length > MAX_LABEL ? "#{label[0, MAX_LABEL - 1]}…" : label
          x = Frame.n(left + (band * (i + 0.5)))
          y = Frame.n(base + 16)
          if slant
            %(<text class="xl" x="#{x}" y="#{y}" text-anchor="end" transform="rotate(-40 #{x} #{y})">#{Frame.esc(shown)}</text>)
          else
            %(<text class="xl" x="#{x}" y="#{y}" text-anchor="middle">#{Frame.esc(shown)}</text>)
          end
        end.join
      end

      def body(ctx)
        case ctx[:style]
        when 'bar' then grouped_bars(ctx)
        when 'stacked', 'percent' then stacked_bars(ctx)
        when 'line' then lines(ctx)
        else areas(ctx)
        end
      end

      def tip(ctx, i, s, value)
        %(<title>#{Frame.esc(ctx[:labels][i])} · #{Frame.esc(ctx[:series][s][:label])}: #{Frame.esc(plain(value, ctx[:words]))}</title>)
      end

      def grouped_bars(ctx)
        inner = ctx[:band] * 0.78
        bw = inner / ctx[:k]
        show = ctx[:n] * ctx[:k] <= 36 && bw >= 16
        out = +''
        ctx[:shown].each_with_index do |values, s|
          values.each_with_index do |v, i|
            x = ctx[:left] + (ctx[:band] * i) + ((ctx[:band] - inner) / 2) + (s * bw)
            top = ctx[:y].(v)
            base = ctx[:top] + ctx[:plot_h]
            out << %(<g>#{tip(ctx, i, s, v)}<rect x="#{Frame.n(x)}" y="#{Frame.n(top)}" width="#{Frame.n([bw - 1, 1].max)}" height="#{Frame.n([base - top, 0].max)}" class="f#{s}"/>)
            out << %(<text class="val" x="#{Frame.n(x + (bw / 2))}" y="#{Frame.n(top - 3)}" text-anchor="middle">#{Frame.esc(fmt(v, ctx[:words], compact: true))}</text>) if show && v.positive?
            out << '</g>'
          end
        end
        out
      end

      def stacked_bars(ctx)
        inner = ctx[:band] * 0.78
        base = Array.new(ctx[:n], 0.0)
        out = +''
        ctx[:shown].each_with_index do |values, s|
          values.each_with_index do |v, i|
            next unless v.positive?

            x = ctx[:left] + (ctx[:band] * i) + ((ctx[:band] - inner) / 2)
            y1 = ctx[:y].(base[i] + v)
            y0 = ctx[:y].(base[i])
            out << %(<g>#{tip(ctx, i, s, ctx[:series][s][:values][i])}<rect x="#{Frame.n(x)}" y="#{Frame.n(y1)}" width="#{Frame.n(inner)}" height="#{Frame.n(y0 - y1)}" class="f#{s}"/>)
            if y0 - y1 >= 14 && inner >= 26
              text = ctx[:style] == 'percent' ? "#{v.round}%" : fmt(ctx[:series][s][:values][i], ctx[:words], compact: true)
              out << %(<text class="val k#{s}" x="#{Frame.n(x + (inner / 2))}" y="#{Frame.n(((y0 + y1) / 2) + 3.5)}" text-anchor="middle">#{Frame.esc(text)}</text>)
            end
            out << '</g>'
            base[i] += v
          end
        end
        if ctx[:style] == 'stacked' && ctx[:n] <= 36
          ctx[:totals].each_with_index do |t, i|
            next unless t.positive?

            out << %(<text class="tot" x="#{Frame.n(ctx[:left] + (ctx[:band] * (i + 0.5)))}" y="#{Frame.n(ctx[:y].(t) - 4)}" text-anchor="middle">#{Frame.esc(fmt(t, ctx[:words], compact: true))}</text>)
          end
        end
        out
      end

      def lines(ctx)
        out = +''
        ctx[:shown].each_with_index do |values, s|
          pts = values.each_with_index.map { |v, i| [ctx[:left] + (ctx[:band] * (i + 0.5)), ctx[:y].(v)] }
          out << %(<polyline points="#{pts.map { |x, yy| "#{Frame.n(x)},#{Frame.n(yy)}" }.join(' ')}" class="s#{s}"/>)
          pts.each_with_index do |(x, yy), i|
            out << %(<g>#{tip(ctx, i, s, values[i])}<circle cx="#{Frame.n(x)}" cy="#{Frame.n(yy)}" r="3.5" class="f#{s}"/></g>)
          end
        end
        out
      end

      def areas(ctx)
        n = ctx[:n]
        lower = Array.new(n, 0.0)
        out = +''
        ctx[:shown].each_with_index do |values, s|
          upper = values.each_with_index.map { |v, i| lower[i] + v }
          xs = ->(i) { Frame.n(ctx[:left] + (ctx[:band] * (i + 0.5))) }
          forward = upper.each_with_index.map { |u, i| "#{xs.(i)},#{Frame.n(ctx[:y].(u))}" }
          back = lower.each_with_index.map { |l, i| "#{xs.(i)},#{Frame.n(ctx[:y].(l))}" }.reverse
          out << %(<g><title>#{Frame.esc(ctx[:series][s][:label])}</title><polygon points="#{(forward + back).join(' ')}" class="f#{s}" opacity=".88"/></g>)
          lower = upper
        end
        out
      end

      # --- legend -----------------------------------------------------------------------------

      def legend_layout(series, x1, x2)
        rows = [[]]
        used = 0.0
        series.each_with_index do |s, i|
          width = (s[:label].length * 6.2) + 26
          if used + width > x2 - x1 && !rows.last.empty?
            rows << []
            used = 0.0
          end
          rows.last << [i, used, width]
          used += width
        end
        { rows: rows, height: rows.size * 18 }
      end

      def legend_svg(series, legend, x0, y0)
        legend[:rows].each_with_index.flat_map do |row, r|
          row.map do |i, offset, _width|
            x = x0 + offset
            yy = y0 + (r * 18)
            %(<rect x="#{Frame.n(x)}" y="#{Frame.n(yy)}" width="10" height="10" rx="2" class="f#{i}"/>) +
              %(<text class="leg" x="#{Frame.n(x + 15)}" y="#{Frame.n(yy + 9)}">#{Frame.esc(series[i][:label])}</text>)
          end
        end.join
      end
    end
  end
end
