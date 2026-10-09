# frozen_string_literal: true

require_relative '../records'

module Mcp
  module Tools
    # The conditions every tool that selects records accepts, described once.
    WHERE_SCHEMA = {
      type: 'array',
      description: 'Conditions that must ALL hold. Omit to use every record of the form. One condition per field.',
      items: {
        type: 'object',
        properties: {
          field: { type: 'string', description: 'Field name from describe_form' },
          op: { type: 'string', enum: Records::OPS.keys,
                description: 'contains (default, ignores case/accents) | equals (exact: ids, DNI, codes) | ' \
                             'not_contains | not_equals | between | on_or_after | on_or_before (the last three: date fields only)' },
          value: { type: 'string', description: 'Text to match; for a date op, the date. Fixed-list fields: the id or the label' },
          start: { type: 'string', description: 'between only: first date, YYYY-MM-DD or "today"' },
          end: { type: 'string', description: 'between only: last date, YYYY-MM-DD or "today"' },
          or_empty: { type: 'boolean', description: 'true = also accept records with no value in this field' }
        },
        required: ['field']
      }
    }.freeze

    # The same conditions, without the long descriptions, for the tools that only reuse them (search_records
    # carries the full explanation): keeps the cost of listing every tool down.
    WHERE_SCHEMA_BRIEF = {
      type: 'array',
      description: 'Conditions that must ALL hold, as in search_records: [{field, op, value | start/end, or_empty}]. Omit to use every record.',
      items: {
        type: 'object',
        properties: {
          field: { type: 'string', description: 'Field name' },
          op: { type: 'string', enum: Records::OPS.keys, description: 'Default contains' },
          value: { type: 'string', description: 'Text or date to match' },
          start: { type: 'string', description: 'between only' },
          end: { type: 'string', description: 'between only' },
          or_empty: { type: 'boolean', description: 'Also accept records with no value' }
        },
        required: ['field']
      }
    }.freeze

    class SearchRecords < Mcp::Tool
      DEFAULT_LIMIT = 25
      MAX_LIMIT = 200

      tool_name 'search_records'
      title "Search records"
      summary "Search the organisation's own records (people, projects, publications, funding): text, exact value or date. Also counts."
      context :forms
      description <<~TEXT
        where = list of conditions, ALL must hold: {"field": name, "op": op, "value": text}.
        ops: contains (default; ignores case and accents), equals (exact: ids, DNI, codes), not_contains, not_equals;
        dates only: between {"start","end"}, on_or_after, on_or_before. A date is YYYY-MM-DD or the word "today".
        "or_empty": true also accepts records with no value in that field. Fixed-list fields take the id or the label.
        One condition per field. No where = every record of the form.

        Examples:
          person by surname: {"form":"member","where":[{"field":"member_surnames","op":"contains","value":"garcia"}]}
          running now: {"form":"project","where":[{"field":"project_start_date","op":"on_or_before","value":"today"},{"field":"project_end_date","op":"on_or_after","value":"today","or_empty":true}]}
          by key: {"form":"funding_commitment","where":[{"field":"commitment_member","op":"equals","value":"12345678Z"}]}

        Each record: form, id, label, dates (date fields), fields (the rest), value_labels (readable text for fixed-list
        values). total = matches; if has_more, raise offset for the next page. total 0 means nothing matched: say so.
        HOW MANY? Set limit 0: you get only the total (e.g. {"form":"member","where":[{"field":"member_status","op":"equals","value":"active"}],"limit":0}).
        No match for a name? Retry with the surname alone. SEVERAL people match a name? Stop and ask the user which one
        (show each label and a distinguishing detail); never pick one yourself.
      TEXT
      param :form, type: 'string', required: true, description: 'Form name from describe_form'
      param :where, **Mcp::Tools::WHERE_SCHEMA
      param :fields, type: 'array', items: { type: 'string' },
                     description: 'Only return these fields (names from describe_form). Saves space on wide forms.'
      param :limit, type: 'integer', description: "Records per page (default #{DEFAULT_LIMIT}, max #{MAX_LIMIT}). 0 = count only: returns the total, no records"
      param :offset, type: 'integer', description: 'Skip this many matches (for the next page). Default 0.'

      def self.run(args)
        ctx = Records::Context.new
        form = ctx.form!(args['form'])
        params = ctx.search_params(form, args['where'])
        limit = (args['limit'] || DEFAULT_LIMIT).to_i.clamp(0, MAX_LIMIT)
        offset = [args['offset'].to_i, 0].max
        only = args['fields'].is_a?(Array) ? args['fields'].map { |f| ctx.field!(form, f)[:questionclass] } : nil

        graphs = execute_search(dataset_type: form.name, search_params: params).uniq.sort
        return { form: form.name, total: graphs.size, returned: 0, records: [] } if limit.zero? # a count: nothing to page through

        page = graphs.slice(offset, limit) || []
        records = ctx.build_records(form, page, only_fields: only)
        { form: form.name, total: graphs.size, returned: records.size, offset: offset,
          has_more: offset + records.size < graphs.size, records: records }
      end
    end
  end
end
