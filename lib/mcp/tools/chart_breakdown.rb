# frozen_string_literal: true

require_relative 'chart_over_time'

module Mcp
  module Tools
    class ChartBreakdown < Mcp::Tool
      tool_name 'chart_breakdown'
      title 'Chart a breakdown'
      summary 'Make a bar chart of records by category as they are now (projects by status, people by gender). Use for any such chart.'
      description <<~TEXT
        Draws a chart of how a total divides among categories (no years), in the institute's colours, ready to paste into a
        report or slides. Use it for "what is X made up of?", "how is X split by Y?", "X by Y and Z". You give the QUERY,
        as for the aggregate tool (form, where, measure, field, group_by): the server computes the numbers and draws them,
        so nothing is copied through you. group_by is required: one field (bars, biggest first) or two (the first is the
        horizontal axis, the second splits each bar, as 100% shares by default).

        To describe a moment, filter with where: the people who are here now are those who started on or before today and
        have not ended (start on_or_before today; end on_or_after today with or_empty true).
        style: bar | stacked | percent | line | area (default: bar for one group, percent for two; percent shows the share
        within each bar, use stacked for absolute numbers). More than 12 categories on the axis: the smallest are merged
        into "Other". shape: slide (16:9, default) or report (3:2); the other is always offered as a download.
        The picture has a caption saying what was asked and as of when, and download links (SVG, PNG, the numbers).
        By default the chart comes as a PNG image the user can download. Set output html only if the user wants the interactive
        page (hover details, SVG downloads in both shapes, the numbers); set shape report for a Word column.

        Examples:
          gender balance by category of people here now: {"form":"member","group_by":["member_category","member_gender"],"where":[{"field":"member_start_date","op":"on_or_before","value":"today"},{"field":"member_end_date","op":"on_or_after","value":"today","or_empty":true}],"title":"Gender balance by category"}
          how many members of each nationality: {"form":"member","group_by":["member_nationality"],"title":"Members by nationality"}
      TEXT
      param :form, type: 'string', required: true, description: 'Form name from describe_form. Several forms of one kind (e.g. the project forms) share a storage_name: pass it to cover them all in ONE call'
      param :group_by, type: 'array', items: { type: 'string' }, required: true, description: 'One or two field names, or record_form (the kind of record)'
      param :where, **WHERE_SCHEMA_BRIEF
      param :measure, **Aggregate.input_schema[:properties]['measure']
      param :field, **Aggregate.input_schema[:properties]['field']
      param :style, type: 'string', enum: Widgets::Chart::STYLES, description: 'bar | stacked | percent | line | area (default: bar for one group, percent for two)'
      param :shape, type: 'string', enum: Widgets::Chart::SHAPES.keys, description: 'slide (16:9, default) or report (3:2)'
      param :title, type: 'string', description: 'Heading of the chart'
      param :y_label, type: 'string', description: 'What the numbers are, shown above the axis (default: derived)'
      param :top_n, type: 'integer', description: 'Most split categories shown, the rest merged into Other (default 8)'
      param :output, type: 'string', enum: ChartSupport::OUTPUTS, description: 'png (default): an image attachment, the cheapest. html: the interactive page with downloads. both'

      def self.run(args)
        groups = Array(args['group_by']).flatten.compact.map(&:to_s).reject { |g| g.strip.empty? }
        raise ToolError, 'group_by is required: the field(s) to split by. For a chart over the years use chart_over_time.' if groups.empty?

        ChartSupport.build(args.reject { |k, _| %w[over_time from to].include?(k) }, mode: :breakdown)
      end
    end
  end
end
