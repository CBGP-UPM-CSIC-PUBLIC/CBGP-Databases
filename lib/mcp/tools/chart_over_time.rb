# frozen_string_literal: true

require 'base64'
require 'digest'
require_relative '../records'
require_relative '../aggregation'
require_relative '../widgets/chart'
require_relative '../widgets/raster'
require_relative 'aggregate'

module Mcp
  module Tools
    # What the two chart tools share: take the QUERY (not numbers), run the aggregation on the server, draw it in
    # the deployment's theme, and say in a caption exactly what was asked, so the chart can be rebuilt next year.
    module ChartSupport
      OUTPUTS = %w[png html both].freeze

      module_function

      # @return [Mcp::Result]
      def build(args, mode:)
        output = (args['output'] || 'png').to_s.strip.downcase
        raise ToolError, "output must be one of: #{OUTPUTS.join(', ')}." unless OUTPUTS.include?(output)

        ctx = Records::Context.new
        form = ctx.form!(args['form'])
        today = Date.today
        data = Aggregation.run(ctx: ctx, form: form, where: args['where'], measure: args['measure'], field: args['field'],
                               group_by: args['group_by'], over_time: args['over_time'], from: args['from'], to: args['to'], today: today)
        language = current_language
        words = Widgets::Chart::WORDS[Widgets::Chart::WORDS.key?(language) ? language : 'en']
        table = Widgets::Chart.table_from_rows(data[:rows], top_n: (args['top_n'] || 8).to_i.clamp(2, Widgets::Chart::MAX_SERIES), words: words,
                                                            single_label: y_default(data, words), max_x: mode == :breakdown ? 12 : nil)
        style = pick_style(args['style'], table, mode)
        title = args['title'].to_s.strip
        drawn = Widgets::Chart.render(table: table, style: style, shape: (args['shape'] || 'slide').to_s, title: title, language: language,
                                      y_label: args['y_label'].to_s.strip.then { |l| l.empty? ? y_default(data, words) : l },
                                      x_title: mode == :over_time ? words[:year] : words[:category], notes: caption(data, form, words, language, mode))
        response(drawn, data, table, style, output)
      end

      def pick_style(requested, table, mode)
        style = requested.to_s.strip.downcase
        return style unless style.empty?
        return 'bar' if table.series.size == 1

        mode == :over_time ? 'stacked' : 'percent'
      end

      def y_default(data, words)
        data[:measure] == 'count' ? words[:records] : words[:total_of]
      end

      # What was asked, in a sentence or two, for the line under the chart.
      def caption(data, form, words, language, mode)
        lines = []
        what = data[:measure] == 'count' ? words[:count_of] : "#{words[:sum_of]} #{data[:measure].sub(/\A\w+ of /, '')}"
        labels = data[:by_labels] || data[:by]
        by = labels.empty? ? '' : " #{words[:by]} #{labels.join(' / ')}"
        over = (ot = data[:over_time]) ? "; #{words.fetch(:"mode_#{ot[:mode]}")}" : ''
        lines << "#{what} #{form.label} #{words[:records_noun]}#{by}#{over}."
        lines << "#{words[:data_as_of]} #{data[:as_of]}; #{data[:records_considered]} #{words[:records_read]}."
        if data[:excluded]
          left_out = data[:excluded].map { |why, n| "#{n} (#{why})" }.join(', ')
          lines << "#{words[:left_out]}: #{left_out}."
        end
        lines << words[:partial_year].sub('%{year}', Date.today.year.to_s) if mode == :over_time && data.dig(:over_time, :mode).to_s.start_with?('active')
        lines
      end

      # png (the default) attaches the chart as an image: the agent program keeps a file and the model reads only
      # its name, which is by far the cheapest way to deliver a picture. html is the interactive page with
      # downloads (both shapes as SVG and PNG, the numbers): the whole page becomes part of the conversation.
      def response(drawn, data, table, style, output)
        png = Widgets::Raster.png(drawn[:svg], width: png_width(drawn[:svg])) if %w[png both].include?(output)
        blocks = []
        blocks << { type: 'resource', resource: { uri: "ui://chart/#{Digest::SHA1.hexdigest(drawn[:html])[0, 12]}", mimeType: 'text/html', text: drawn[:html] } } unless output == 'png' && png
        blocks << { type: 'image', data: Base64.strict_encode64(png), mimeType: 'image/png' } if png
        summary = { style: style, shape: drawn[:shape], x: table.x_labels, series: table.series.map { |s| { label: s[:label], values: s[:values].map { |v| v.round(2) } } },
                    measure: data[:measure], as_of: data[:as_of], excluded: data[:excluded],
                    attached: { html: !(output == 'png' && png), png: !png.nil? }, note: note_for(output, png, drawn[:shape]) }.compact
        Result.new(summary, blocks)
      end

      # The PNG is drawn at twice the picture's own width, so a Word column stays as sharp as a slide.
      def png_width(svg)
        (svg[/width="(\d+)"/, 1] || 960).to_i * 2
      end

      def note_for(output, png, shape)
        other = shape == 'slide' ? 'report' : 'slide'
        if png && output == 'png'
          "The chart is attached as a PNG image (shape #{shape}). Describe it in a sentence and mention anything under excluded. Ask for shape #{other} for the other proportion " \
            '(slide 16:9 for presentations, report 3:2 for a Word column); ask for output html for an interactive page with SVG downloads, both shapes and the numbers.'
        elsif png
          'The chart is attached as an interactive page and as a PNG image. The page has download links for SVG and PNG (slide and report shapes) and for the numbers.'
        else
          "The chart is attached as an interactive page#{output == 'png' ? ' (a PNG could not be made on this server)' : ''}, with download links for SVG and PNG (slide and report shapes) " \
            'and for the numbers. Describe it in a sentence and mention anything under excluded; if you cannot display it, give the numbers in text.'
        end
      end
    end

    class ChartOverTime < Mcp::Tool
      tool_name 'chart_over_time'
      title 'Chart over the years'
      summary 'Make a line or bar chart of a count or total over the years (headcount, funding, papers per year). Use for any such chart.'
      description <<~TEXT
        Draws a chart of how something changed over calendar years, in the institute's colours, ready to paste into a
        report or slides. Use it for "how has X changed over the years?", "X by year and by Y". You give the QUERY, exactly
        as for the aggregate tool (read its description for form, where, measure, field, group_by, over_time with mode
        by_date / active_at_end / active_during / spread, from, to): the server computes the numbers and draws them, so
        nothing is copied through you. over_time is required.

        style: bar (side by side) | stacked | percent (100% stacked, for shares) | line | area. Leave it out: it is stacked
        when there are categories, else bar. Use line to show a trend of a few categories, percent for composition over time.
        shape: slide (16:9, default) or report (3:2); the other is always offered as a download. top_n: how many categories
        to show (default 8); the smallest are merged into "Other".
        The picture has a caption saying what was asked and as of when, and download links (SVG, PNG, the numbers).
        By default the chart comes as a PNG image the user can download. Set output html only if the user wants the interactive
        page (hover details, SVG downloads in both shapes, the numbers); set shape report for a Word column.

        Examples:
          members by gender at each year end: {"form":"member","group_by":["member_gender"],"over_time":{"mode":"active_at_end","start_field":"member_start_date","end_field":"member_end_date"},"title":"Members by gender"}
          papers per year, as a line: {"form":"publication","over_time":{"mode":"by_date","date_field":"publication_date"},"style":"line","from":"2018"}
      TEXT
      param :form, type: 'string', required: true, description: 'Form name from describe_form'
      param :over_time, **Aggregate.input_schema[:properties]['over_time'].merge(description: 'Required. How the years are laid out (see the aggregate tool)')
      param :where, **WHERE_SCHEMA_BRIEF
      param :measure, **Aggregate.input_schema[:properties]['measure']
      param :field, **Aggregate.input_schema[:properties]['field']
      param :group_by, type: 'array', items: { type: 'string' }, description: 'One or two field names, or record_form (the kind of record)'
      param :from, type: 'string', description: 'First year, e.g. 2019'
      param :to, type: 'string', description: 'Last year, e.g. 2025'
      param :style, type: 'string', enum: Widgets::Chart::STYLES, description: 'bar | stacked | percent | line | area (default: stacked with categories, else bar)'
      param :shape, type: 'string', enum: Widgets::Chart::SHAPES.keys, description: 'slide (16:9, default) or report (3:2)'
      param :title, type: 'string', description: 'Heading of the chart'
      param :y_label, type: 'string', description: 'What the numbers are, shown above the axis (default: derived)'
      param :top_n, type: 'integer', description: 'Most categories shown, the rest merged into Other (default 8)'
      param :output, type: 'string', enum: ChartSupport::OUTPUTS, description: 'png (default): an image attachment, the cheapest. html: the interactive page with downloads. both'

      def self.run(args)
        raise ToolError, 'over_time is required for this chart: say how the years are laid out (mode by_date, active_at_end, active_during or spread). For numbers without years use chart_breakdown.' if args['over_time'].nil?

        ChartSupport.build(args, mode: :over_time)
      end
    end
  end
end
