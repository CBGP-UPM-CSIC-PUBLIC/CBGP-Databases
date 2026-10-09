# frozen_string_literal: true

require_relative '../records'
require_relative '../aggregation'
require_relative 'search_records'

module Mcp
  module Tools
    class Aggregate < Mcp::Tool
      tool_name 'aggregate'
      title 'Count and total'
      summary 'Count or add up records by category and by year: headcount at year end, funding per year, papers per year.'
      context :dataset
      description <<~TEXT
        Computes numbers over a form's records, on the server, so you never add anything up yourself. Optionally
        splits them by a category (group_by) and lays them out over calendar years (over_time).

        measure: count (default) | sum | avg. sum and avg need field = a list of number/currency fields; the first one
        a record has a value for is used (a form family may keep the same amount under different field names).
        group_by: up to two field names, or the word record_form (which form wrote each record, e.g. the kind of project).
        A record with no value in a group field goes to the group "(none)"; a many-valued field puts it in each group.
        over_time.mode:
          by_date        - a record counts in the YEAR of date_field (papers per year: publication date).
          active_at_end  - a record counts in every year it is "on" at the END of the year: start_field on or before,
                           end_field after or empty (headcount at 31 December). The current year is counted as of today.
          active_during  - counts in every year it was on at ANY point.
          spread         - with measure sum: a record's amount is shared across the years from start_field to end_field in
                           proportion to days, so funding per calendar year adds back up to the totals.
        from / to: first and last year to show.

        Examples:
          headcount per year by gender: {"form":"member","group_by":["member_gender"],"over_time":{"mode":"active_at_end","start_field":"member_start_date","end_field":"member_end_date"}}
          papers per year: {"form":"publication","over_time":{"mode":"by_date","date_field":"publication_date"}}
          funding per year by kind of project: {"form":"project","measure":"sum","field":[<its total-funding fields>],"group_by":["record_form"],"over_time":{"mode":"spread","start_field":"project_start_date","end_field":"project_end_date"}}
          how many by status, no years: {"form":"member","group_by":["member_status"]}

        Answer rows are {period, group, label, value}. "excluded" says how many records were left out for lacking a needed
        field (e.g. no start date): report that to the user, it is a data-quality fact. Check "notes" and "as_of".
      TEXT
      param :form, type: 'string', required: true, description: 'Form name from describe_form (a storage name such as project covers all its forms)'
      param :where, **WHERE_SCHEMA_BRIEF
      param :measure, type: 'string', enum: Aggregation::MEASURES, description: 'count (default), sum or avg'
      param :field, type: 'array', items: { type: 'string' },
                    description: 'For sum/avg: number or currency field names; the first one a record has a value for is used'
      param :group_by, type: 'array', items: { type: 'string' }, description: 'Up to two field names, or record_form'
      param :over_time, type: 'object',
                        description: 'Lay the numbers out over calendar years',
                        properties: {
                          mode: { type: 'string', enum: Aggregation::MODES.keys, description: 'by_date | active_at_end | active_during | spread' },
                          date_field: { type: 'string', description: 'by_date: the date field whose year counts' },
                          start_field: { type: 'string', description: 'active_* and spread: the date a record starts' },
                          end_field: { type: 'string', description: 'active_* (optional: empty = still going) and spread: the date a record ends' },
                          granularity: { type: 'string', enum: %w[year], description: 'year (the only one for now)' }
                        },
                        required: ['mode']
      param :from, type: 'string', description: 'First year to show, e.g. 2019'
      param :to, type: 'string', description: 'Last year to show, e.g. 2025'

      def self.run(args)
        ctx = Records::Context.new
        form = ctx.form!(args['form'])
        Aggregation.run(ctx: ctx, form: form, where: args['where'], measure: args['measure'], field: args['field'],
                        group_by: args['group_by'], over_time: args['over_time'], from: args['from'], to: args['to'])
      end
    end
  end
end
