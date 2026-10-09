# frozen_string_literal: true

require 'bigdecimal'
require 'date'
require_relative 'records'

module Mcp
  # Counts and totals over the records of a form, optionally split by a category and laid out over
  # calendar years - the numbers behind "how has funding changed, by source?", "how many members at the end
  # of each year, by gender?". Nothing here names a form or a field: every name comes from the caller and is
  # checked against the ontology.
  #
  # The arithmetic (.compute) is separate from the reading (Source) so it can be tested with plain data.
  module Aggregation
    NONE = '(none)'
    MEASURES = %w[count sum avg].freeze
    MODES = {
      'by_date' => 'each record counts in the year of date_field',
      'active_at_end' => 'each record counts in every year it is "on" at the END of the year (start_field on or before, end_field after or empty): a headcount at 31 December',
      'active_during' => 'each record counts in every year it was "on" at ANY point (overlaps the year)',
      'spread' => 'with measure sum: each record\'s amount is shared across the years between start_field and end_field in proportion to the days in each year'
    }.freeze
    MAX_ROWS = 600
    MAX_YEARS = 80
    RECORD_FORM = 'record_form'

    Spec = Struct.new(:measure, :value_fields, :group_fields, :mode, :date_field, :start_field, :end_field, :from, :to, keyword_init: true)

    module_function

    # Reads the records and computes the result. +over_time+ is a Hash like
    # {'mode' => 'active_at_end', 'start_field' => 'member_start_date', 'end_field' => 'member_end_date'}.
    def run(ctx:, form:, where: nil, measure: 'count', field: nil, group_by: nil, over_time: nil, from: nil, to: nil, today: Date.today)
      spec = build_spec(ctx, form, measure, field, group_by, over_time, from, to)
      params = ctx.search_params(form, where)
      graphs = execute_search(dataset_type: form.name, search_params: params).uniq
      records = Source.fetch(ctx: ctx, form: form, graphs: graphs, fields: spec_fields(spec), with_form: spec.group_fields.include?(RECORD_FORM))
      result = compute(records: records, spec: spec, today: today)
      decorate(ctx, form, spec, result, today)
    end

    # --- validation -------------------------------------------------------------------------------

    def build_spec(ctx, form, measure, field, group_by, over_time, from, to)
      measure = (measure || 'count').to_s.strip.downcase
      raise ToolError, "measure must be one of: #{MEASURES.join(', ')}." unless MEASURES.include?(measure)

      value_fields = Array(field).flatten.compact.map { |f| f.to_s.strip }.reject(&:empty?)
      if measure == 'count'
        value_fields = []
      else
        raise ToolError, "measure '#{measure}' needs field: the number to add up (a currency, number or percentage field)." if value_fields.empty?

        value_fields = value_fields.map do |name|
          f = ctx.field!(form, name)
          raise ToolError, "Field #{f[:questionclass]} is #{f[:class]}; measure '#{measure}' needs a number or currency field." unless %w[currency number integer].include?(f[:class].to_s)

          f[:questionclass]
        end
      end
      groups = Array(group_by).flatten.compact.map { |g| g.to_s.strip }.reject(&:empty?)
      raise ToolError, 'group_by takes at most two fields.' if groups.size > 2

      groups = groups.map { |g| g.casecmp?(RECORD_FORM) ? RECORD_FORM : ctx.field!(form, g)[:questionclass] }
      spec = Spec.new(measure: measure, value_fields: value_fields, group_fields: groups, from: year_of(from, 'from'), to: year_of(to, 'to'))
      apply_over_time(ctx, form, spec, over_time)
      spec
    end

    def apply_over_time(ctx, form, spec, over_time)
      return if over_time.nil? || (over_time.respond_to?(:empty?) && over_time.empty?)
      raise ToolError, 'over_time must be an object like {"mode":"by_date","date_field":"publication_date"}.' unless over_time.is_a?(Hash)

      granularity = (over_time['granularity'] || 'year').to_s.downcase
      raise ToolError, "Only granularity year is supported for now (got '#{granularity}')." unless granularity == 'year'

      mode = over_time['mode'].to_s.strip.downcase
      raise ToolError, "over_time.mode must be one of: #{MODES.keys.join(', ')}." unless MODES.key?(mode)

      spec.mode = mode
      date_name = lambda do |key|
        name = over_time[key].to_s.strip
        raise ToolError, "over_time.#{key} is required for mode #{mode}." if name.empty?

        f = ctx.field!(form, name)
        raise ToolError, "Field #{f[:questionclass]} is #{f[:class]}, not a date; #{key} must be a date field." unless f[:class].to_s == 'date'

        f[:questionclass]
      end
      if mode == 'by_date'
        spec.date_field = date_name.('date_field')
      else
        spec.start_field = date_name.('start_field')
        spec.end_field = date_name.('end_field') if over_time['end_field'].to_s.strip != '' || mode == 'spread'
        raise ToolError, 'mode spread needs measure sum with a number field.' if mode == 'spread' && spec.measure != 'sum'
      end
    end

    def year_of(value, label)
      return nil if value.nil? || value.to_s.strip.empty?

      text = value.to_s.strip[/\A\d{4}/]
      raise ToolError, "#{label} must be a year such as 2019." unless text

      text.to_i
    end

    def spec_fields(spec)
      ([spec.date_field, spec.start_field, spec.end_field] + spec.value_fields + spec.group_fields).compact.uniq - [RECORD_FORM]
    end

    # --- arithmetic (no database) ----------------------------------------------------------------

    # @param records [Array<Hash>] each { values: { questionclass => [text, ...] }, form: 'form class' }
    # @return [Hash] { cells: { [period, *group keys] => number }, periods: [...], excluded: { reason => count },
    #   considered: }
    def compute(records:, spec:, today: Date.today)
      excluded = Hash.new(0)
      cells = Hash.new(BigDecimal(0))
      counts = Hash.new(0)
      placed = place_records(records, spec, today, excluded)
      placed.each do |rec, contributions|
        value = measure_value(rec, spec, excluded)
        next if value.nil?

        keys_for(rec, spec).each do |group_keys|
          contributions.each do |period, weight|
            cell = [period, *group_keys]
            cells[cell] += value * weight
            counts[cell] += 1
          end
        end
      end
      values = cells.to_h { |cell, sum| [cell, spec.measure == 'avg' ? sum / counts[cell] : sum] }
      { cells: values, periods: periods_of(values), excluded: excluded, considered: records.size }
    end

    # Each record with the periods it falls in and a weight for each: [[record, [[period, weight], ...]], ...].
    def place_records(records, spec, today, excluded)
      return records.map { |r| [r, [[nil, BigDecimal(1)]]] } if spec.mode.nil?

      records.filter_map do |rec|
        parts = case spec.mode
                when 'by_date' then by_date(rec, spec, excluded)
                else interval(rec, spec, today, excluded)
                end
        [rec, parts] if parts && !parts.empty?
      end
    end

    def by_date(rec, spec, excluded)
      date = parse_date(first_value(rec, spec.date_field))
      return excluded_one(excluded, "no #{spec.date_field}") unless date
      return nil unless in_range?(date.year, spec)

      [[date.year, BigDecimal(1)]]
    end

    def interval(rec, spec, today, excluded)
      start = parse_date(first_value(rec, spec.start_field))
      return excluded_one(excluded, "no #{spec.start_field}") unless start

      finish = spec.end_field ? parse_date(first_value(rec, spec.end_field)) : nil
      return excluded_one(excluded, "#{spec.end_field} before #{spec.start_field}") if finish && finish < start
      return excluded_one(excluded, "no #{spec.end_field}") if spec.mode == 'spread' && finish.nil?

      # A headcount is only known up to now; a total spread over a record's life runs to its end, even if that is ahead.
      last_year = spec.mode == 'spread' ? finish.year : [finish ? finish.year : today.year, today.year].min
      (start.year..last_year).filter_map do |year|
        next unless in_range?(year, spec)

        weight = interval_weight(spec.mode, year, start, finish, today)
        [year, weight] if weight.positive?
      end
    end

    def interval_weight(mode, year, start, finish, today)
      first = Date.new(year, 1, 1)
      last = Date.new(year, 12, 31)
      case mode
      when 'active_at_end'
        mark = [last, today].min
        start <= mark && (finish.nil? || finish >= mark) ? BigDecimal(1) : BigDecimal(0)
      when 'active_during'
        (start <= last && (finish.nil? || finish >= first)) ? BigDecimal(1) : BigDecimal(0)
      else # spread: share of the record's days that fall in this year
        overlap = [finish, last].min - [start, first].max + 1
        overlap.positive? ? BigDecimal(overlap.to_i) / BigDecimal((finish - start).to_i + 1) : BigDecimal(0)
      end
    end

    def in_range?(year, spec)
      (spec.from.nil? || year >= spec.from) && (spec.to.nil? || year <= spec.to)
    end

    def excluded_one(excluded, reason)
      excluded[reason] += 1
      nil
    end

    def measure_value(rec, spec, excluded)
      return BigDecimal(1) if spec.measure == 'count'

      spec.value_fields.each do |name|
        text = first_value(rec, name)
        next if text.nil?

        number = begin
          BigDecimal(text.to_s.strip)
        rescue ArgumentError
          nil
        end
        return number if number
      end
      excluded["no #{spec.value_fields.join(' / ')}"] += 1
      nil
    end

    # The category combinations a record belongs to (a many-valued field puts it in several; none = "(none)").
    def keys_for(rec, spec)
      lists = spec.group_fields.map do |name|
        values = name == RECORD_FORM ? [rec[:form]].compact : Array(rec[:values][name]).map(&:to_s).reject { |v| v.strip.empty? }
        values.empty? ? [NONE] : values.uniq
      end
      lists.empty? ? [[]] : lists.first.product(*lists.drop(1))
    end

    def first_value(rec, name)
      Array(rec[:values][name]).map(&:to_s).find { |v| !v.strip.empty? }
    end

    def parse_date(text)
      return nil if text.nil?

      Date.iso8601(text.to_s[0, 10])
    rescue ArgumentError
      nil
    end

    def periods_of(values)
      values.keys.map(&:first).uniq.sort_by { |p| p.nil? ? -1 : p }
    end

    # --- presentation ----------------------------------------------------------------------------

    def decorate(ctx, form, spec, result, today)
      labels = group_labels(ctx, form, spec, result[:cells])
      rows = result[:cells].map do |(period, *keys), value|
        row = {}
        row[:period] = period.to_s if period
        unless keys.empty?
          row[:group] = keys.size == 1 ? keys.first : keys
          row[:label] = keys.size == 1 ? labels.dig(0, keys.first) : keys.each_with_index.map { |k, i| labels.dig(i, k) }
        end
        row[:value] = number(value, spec)
        row
      end
      rows.sort_by! { |r| [r[:period].to_s, Array(r[:group]).join('|')] }
      truncated = rows.size > MAX_ROWS
      out = { form: form.name, measure: describe_measure(spec), by: spec.group_fields, rows: rows.first(MAX_ROWS),
              records_considered: result[:considered], as_of: today.iso8601 }
      out[:over_time] = describe_over_time(spec, today) if spec.mode
      out[:excluded] = result[:excluded] unless result[:excluded].empty?
      out[:notes] = notes_for(spec, result, today, truncated).then { |n| n.empty? ? nil : n }
      out.compact
    end

    def number(value, spec)
      return value.to_i if spec.measure == 'count' && value.frac.zero?

      value.round(2).to_f
    end

    def describe_measure(spec)
      spec.measure == 'count' ? 'count' : "#{spec.measure} of #{spec.value_fields.join(' or ')}"
    end

    def describe_over_time(spec, today)
      { mode: spec.mode, granularity: 'year', fields: [spec.date_field, spec.start_field, spec.end_field].compact,
        current_year_is_partial_as_of: today.iso8601 }
    end

    def notes_for(spec, result, today, truncated)
      notes = []
      notes << "The current year (#{today.year}) is counted as of #{today.iso8601}, not as of 31 December." if spec.mode && spec.mode != 'by_date' && spec.mode != 'spread'
      notes << 'A record with no end date is treated as still going.' if %w[active_at_end active_during].include?(spec.mode) && spec.end_field
      notes << 'Amounts are shared across calendar years in proportion to days; they add back up to each record\'s total.' if spec.mode == 'spread'
      notes << "Records without the field(s) needed were left out and are listed under excluded (#{result[:excluded].values.sum})." unless result[:excluded].empty?
      notes << "More than #{MAX_ROWS} rows: only the first #{MAX_ROWS} are shown; narrow it with where, from/to or fewer groups." if truncated
      notes
    end

    # { dimension index => { key => readable label } } for the groups that appear.
    def group_labels(ctx, form, spec, cells)
      spec.group_fields.each_with_index.to_h do |name, i|
        keys = cells.keys.map { |c| c[i + 1] }.uniq
        [i, keys.to_h { |k| [k, label_for(ctx, form, name, k)] }]
      end
    end

    def label_for(ctx, form, name, key)
      return key if key == NONE

      if name == RECORD_FORM
        found = ctx.all_forms.find { |f| f.name == key }
        return found ? found.label : key
      end
      field = ctx.fields(form.name).find { |f| f[:questionclass] == name }
      return key unless field

      ctx.vocabulary_label(field, key) || key
    end

    # --- reading ---------------------------------------------------------------------------------

    # Reads just the fields needed, not the whole record: for 924 members and five fields one query takes a
    # third of a second, where reading every field of 100 records takes about eight seconds.
    module Source
      CHUNK = 1000

      module_function

      # @return [Array<Hash>] { values: { questionclass => [text, ...] }, form: stamp or nil }, one per graph
      def fetch(ctx:, form:, graphs:, fields:, with_form: false)
        return [] if graphs.empty?

        defs = fields.to_h { |f| [f, ctx.fields(form.name).find { |d| d[:questionclass] == f }] }
        single, multiple = fields.partition { |f| !ctx.multiple?(defs[f] || {}) }
        by_graph = graphs.to_h { |g| [g.to_s, { values: Hash.new { |h, k| h[k] = [] }, form: nil }] }
        graphs.each_slice(CHUNK) do |slice|
          read(slice, single, by_graph) unless single.empty?
          multiple.each { |f| read(slice, [f], by_graph) }
          stamps(slice).each { |g, stamp| by_graph[g][:form] = stamp } if with_form
        end
        by_graph.values.map { |r| { values: r[:values].transform_values(&:uniq), form: r[:form] } }
      end

      def read(graphs, fields, by_graph)
        fields.each { |f| validate_local_name!(f, field: 'field') }
        select = "?graph #{fields.map { |f| "?#{f}" }.join(' ')}"
        optional = fields.map do |f|
          "OPTIONAL { GRAPH ?graph { ?dataset sio:SIO_000008 ?a_#{f} . ?a_#{f} sio:SIO_000300 ?#{f} . ?a_#{f} rdf:type cbgp:#{f} . } }"
        end.join("\n")
        query = "#{PREFIXES}\nSELECT #{select} WHERE {\nVALUES ?graph { #{graphs.map { |g| "<#{g}>" }.join(' ')} }\n#{optional}\n}"
        DATABASE.query(query).each do |row|
          bucket = by_graph[row[:graph].to_s] or next
          fields.each { |f| bucket[:values][f] << row[f.to_sym].to_s if row.bound?(f.to_sym) }
        end
      end

      def stamps(graphs)
        batch_retrieve_record_forms(graph_uris: graphs)
      end
    end
  end
end
