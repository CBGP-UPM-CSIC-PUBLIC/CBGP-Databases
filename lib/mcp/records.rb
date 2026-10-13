# frozen_string_literal: true

require_relative 'tool'

module Mcp
  # Everything the tools share about RECORDS: what a form is, what a field is,
  # how a record is identified, labelled and serialized, and how a model's
  # search conditions become the search engine's parameters. Nothing here
  # names a particular form or field; it all comes from the ontology.
  #
  # The record identity every tool uses, so one tool's output is the next
  # tool's input:   { form:, id:, label: }
  #   form   the form class that wrote the record (the dcterms:type stamp),
  #          e.g. "funding_commitment"
  #   id     the record's permanent id (a UUID), unchanged by edits
  #   label  what a person would call it, e.g. "Álvarez, Olga"
  module Records
    # description: what the form's records ARE, in the current language (the
    # ontology's rdfs:comment on the form; nil when it has none).
    FormInfo = Struct.new(:name, :storage, :label, :description, :category, keyword_init: true)

    # The local:form-category the listed forms carry: the staff-facing data
    # forms (what the web app's search menus use). Other categories, such as
    # member-facing submission forms, are not offered to a model.
    LISTED_CATEGORY = 'Core'
    SUPPORTED_LANGUAGES = %w[en es].freeze

    OPS = {
      'contains' => 'text contains the value (ignores case and accents) - the default',
      'equals' => 'the stored value is exactly the value (use for ids, DNI, codes, controlled-vocabulary ids)',
      'not_contains' => 'text does NOT contain the value (records with no value at all also match)',
      'not_equals' => 'the stored value is NOT exactly the value (records with no value at all also match)',
      'between' => 'a date lies between start and end (inclusive; either may be omitted). Dates only',
      'on_or_after' => 'a date is on or after the value. Dates only',
      'on_or_before' => 'a date is on or before the value. Dates only'
    }.freeze

    module_function

    def blank_value?(value)
      value.nil? || (value.respond_to?(:empty?) && value.empty?) || (value.is_a?(String) && value.strip.empty?)
    end

    def fold(text)
      text.to_s.unicode_normalize(:nfd).gsub(/\p{Mn}/, '').downcase.strip
    end

    def date_class?(field)
      field[:class].to_s == 'date'
    end

    def reference_field?(field)
      !field[:references_target].to_s.empty? && !field[:references_via].to_s.empty?
    end

    def fragment(uri)
      uri.to_s.split('#').last
    end

    # Answers that depend only on the loaded ontology (a form's fields, a vocabulary, the label rules),
    # kept for the life of the process and shared by every call: working them out costs seconds, and
    # they cannot change until the ontology does. Keyed by the loaded ontology object, so a refresh
    # (which loads a new one) starts clean and a stale answer can never outlive an edit. Never put
    # anything read from the RECORDS here.
    module Shared
      @cache = {}
      @lock = Mutex.new

      module_function

      def fetch(*key)
        full_key = [$ontology.object_id] + key
        @lock.synchronize do
          @cache.clear unless @cache.keys.all? { |k| k.first == $ontology.object_id }
          return @cache[full_key] if @cache.key?(full_key)
        end
        value = yield # worked out outside the lock: two calls at once may both do it, which is harmless
        @lock.synchronize { @cache[full_key] = value }
      end

      # For specs: forget everything.
      def reset!
        @lock.synchronize { @cache.clear }
      end
    end

    # Works out, once, everything Shared keeps (the fields of every listed form, their label rules and
    # vocabularies, in each language), so the first question after a start does not pay for it. Meant for a
    # background thread at boot; any failure only means the first call does the work itself.
    def warm_up
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      previous = Thread.current[:language]
      SUPPORTED_LANGUAGES.each do |language|
        Thread.current[:language] = language
        ctx = Context.new
        ctx.forms.each do |form|
          ctx.label_spec(form.storage)
          ctx.fields(form.name).each { |field| SUPPORTED_LANGUAGES.each { |lang| ctx.vocabulary(field, lang) } }
        end
      end
      warn format('[MCP] warm-up done in %<ms>dms', ms: (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000)
    rescue StandardError => e
      warn "[MCP] warm-up skipped: #{e.class}: #{e.message}"
    ensure
      Thread.current[:language] = previous
    end

    # One tool call's working set: memoizes the ontology lookups so a call
    # that touches many records asks the ontology each question once. Create
    # one per call. What depends only on the ontology is also kept across
    # calls (see Shared); what comes from the records never is.
    class Context
      def initialize
        @fields = {}
        @vocab = {}
        @label_specs = {}
        @references = {}
        @record_labels = {}
      end

      # --- forms ---------------------------------------------------------

      # The forms the tools list, describe and search by name: the staff-facing
      # data forms - the same category the web app's search menus offer
      # (get_databases type "Core"), so member-facing submission forms, which
      # nobody queries, stay out of what the model sees. Labelled and described
      # in the current language (English where there is no text in it).
      def forms
        @forms ||= all_forms.select { |f| f.category == LISTED_CATEGORY }
      end

      # Every form the ontology declares, whatever its category. Only used to
      # make a name that appears in a record (its form stamp) resolvable, so an
      # id a tool returned never dead-ends; never listed.
      def all_forms
        @all_forms ||= Shared.fetch(:all_forms, current_language) do
          comments = ontology_comments
          language = current_language
          rows = SPARQL.parse(<<~SPARQL).execute($ontology)
            #{PREFIXES}
            SELECT ?form ?label ?category WHERE {
              ?form rdfs:subClassOf cbgp:forms ;
                    rdfs:label ?label ;
                    local:dbname ?dbname .
              OPTIONAL { ?form local:form-category ?category }
              FILTER (lang(?label) = "#{validate_local_name!(language, field: 'language')}")
            }
          SPARQL
          rows.map do |row|
            name = Records.fragment(row[:form])
            FormInfo.new(name: name, storage: storage_dbname_for(name), label: row[:label].to_s,
                         description: pick_language(comments[name]), category: row.bound?(:category) ? row[:category].to_s : nil)
          end.uniq(&:name).sort_by(&:name)
        end
      end

      # What the dataset as a whole is (the ontology's rdfs:comment on the
      # root forms class), in the current language; nil if it has none.
      def dataset_description
        pick_language(ontology_comments['forms'])
      end

      # { class name => { language => text } } for every comment on the form
      # classes and on their root, read once per call.
      def ontology_comments
        @ontology_comments ||= Shared.fetch(:comments) do
          SPARQL.parse(<<~SPARQL).execute($ontology).each_with_object(Hash.new { |h, k| h[k] = {} }) do |row, out|
            #{PREFIXES}
            SELECT ?form ?comment WHERE {
              { ?form rdfs:subClassOf cbgp:forms } UNION { BIND(cbgp:forms AS ?form) }
              ?form rdfs:comment ?comment .
            }
          SPARQL
            lang = row[:comment].respond_to?(:language) ? row[:comment].language.to_s : ''
            out[Records.fragment(row[:form])][lang] = row[:comment].to_s.strip unless lang.empty?
          end
        end
      end
      private :ontology_comments

      def pick_language(by_language)
        return nil unless by_language

        text = by_language[current_language.to_s] || by_language['en']
        text.nil? || text.empty? ? nil : text
      end
      private :pick_language

      def storages
        forms.map(&:storage).uniq.sort
      end

      # Accepts a form class name ("funding_commitment") or a storage name
      # ("commitment"); anything else raises with the valid choices.
      def form!(name)
        wanted = name.to_s.strip
        raise ToolError, 'form is required. Call describe_form with no arguments to list the forms.' if wanted.empty?

        found = forms.find { |f| f.name == wanted } ||
                forms.find { |f| f.name.casecmp?(wanted) } ||
                forms.find { |f| Records.fold(f.label) == Records.fold(wanted) } ||
                all_forms.find { |f| f.name == wanted } # not listed, but a record may carry it
        return found if found

        storage = storages.find { |s| s.casecmp?(wanted) }
        return FormInfo.new(name: storage, storage: storage, label: storage) if storage

        raise ToolError, "Unknown form '#{wanted}'. Valid forms: #{forms.map(&:name).join(', ')}. " \
                         "(Storage names also work: #{storages.join(', ')}.)"
      end

      # --- fields --------------------------------------------------------

      def fields(form_name)
        @fields[form_name] ||= Shared.fetch(:fields, form_name, current_language) { CBGP::Dataset.fields_for(form_name) }
      end

      def field!(form, name)
        wanted = name.to_s.strip
        found = fields(form.name).find { |f| f[:questionclass] == wanted } ||
                fields(form.name).find { |f| f[:questionclass].casecmp?(wanted) } ||
                fields(form.name).find { |f| Records.fold(f[:label]) == Records.fold(wanted) }
        return found if found

        raise ToolError, "Form '#{form.name}' has no field '#{wanted}'. Valid fields: " \
                         "#{fields(form.name).map { |f| f[:questionclass] }.join(', ')}. Call describe_form for their meaning."
      end

      def multiple?(field)
        field[:cardinality].to_s.casecmp?('multiple')
      end

      # Every cross-reference field, on any form, that points at records of
      # +storage+: [{ form: FormInfo, field: descriptor }]. One entry per
      # (storage, field): forms that share a storage and a field are the same
      # relation, and searching the storage finds all of them at once.
      def inbound_references(storage)
        forms.flat_map do |f|
          fields(f.name).filter_map do |fld|
            { form: f, field: fld } if Records.reference_field?(fld) && storage_dbname_for(fld[:references_target]) == storage
          end
        end.uniq { |r| [r[:form].storage, r[:field][:questionclass]] }
      end

      # --- controlled vocabularies ---------------------------------------

      # [{id:, label:, group:}] for a controlled-vocabulary field, [] for any
      # other. The ids are what records store. For a tree-select field these
      # are the selectable leaves, +group+ naming where each sits in the tree.
      def vocabulary(field, language = current_language)
        return [] unless controlled_vocabulary_field?(field)

        block = Records.fragment(field[:answers])
        tree = field[:widget].to_s.end_with?('treeselector')
        @vocab[[block, tree, language]] ||= Shared.fetch(:vocabulary, block, tree, language) do
          in_language(language) do
            options = tree ? tree_vocabulary(block) : flat_vocabulary(block)
            options = tree ? flat_vocabulary(block) : tree_vocabulary(block) if options.empty?
            options
          end
        end
      end

      # Runs the block with the UI language set to +language+, then restores it.
      def in_language(language)
        previous = Thread.current[:language]
        Thread.current[:language] = language
        yield
      ensure
        Thread.current[:language] = previous
      end
      private :in_language

      def flat_vocabulary(block)
        get_answer_block_query(ablockid: block).map { |r| { id: Records.fragment(r[:aid]), label: r[:label].to_s } }
      end
      private :flat_vocabulary

      def tree_vocabulary(block)
        nodes = JSON.parse(get_hierarchical_answer_block_query(ablockid: block))
        collect_leaves(nodes, [])
      rescue StandardError
        []
      end
      private :tree_vocabulary

      def collect_leaves(nodes, path)
        nodes.flat_map do |node|
          children = node['children'] || []
          if children.empty?
            [{ id: node['id'], label: node['text'].to_s, group: path.empty? ? nil : path.join(' > ') }.compact]
          else
            collect_leaves(children, path + [node['text'].to_s])
          end
        end
      end
      private :collect_leaves

      # The stored id for a value a model supplied for a vocabulary field: the
      # id itself, or the label in ANY supported language (a Spanish question
      # may reach the tool with an English label and the other way round), in
      # any case or accents. Anything else raises, listing what is allowed (a
      # guess must never silently match nothing); a label that two options
      # share raises too, listing their ids.
      def vocabulary_id!(field, value)
        options = vocabulary(field)
        return value if options.empty?

        wanted = Records.fold(value)
        by_id = options.find { |o| Records.fold(o[:id]) == wanted }
        return by_id[:id] if by_id

        [current_language, *(SUPPORTED_LANGUAGES - [current_language])].each do |language|
          by_label = vocabulary(field, language).select { |o| Records.fold(o[:label]) == wanted }
          return by_label.first[:id] if by_label.size == 1

          if by_label.size > 1
            raise ToolError, "'#{value}' matches several values of #{field[:questionclass]}; use one of these ids: " \
                             "#{by_label.map { |o| "#{o[:id]} (#{o[:group]})" }.join('; ')}."
          end
        end
        raise ToolError, "'#{value}' is not a valid value for #{field[:questionclass]}. Valid values (id = label): " \
                         "#{options.map { |o| "#{o[:id]} = #{o[:label]}" }.join('; ')}."
      end

      def vocabulary_label(field, id)
        hit = vocabulary(field).find { |o| o[:id] == id.to_s }
        hit ? hit[:label] : nil
      end

      # --- identity and labels --------------------------------------------

      def graph_uri(form, id)
        "#{BASE_URI}#{form.storage}/context/#{validate_iri_component!(id.to_s.strip, field: 'id')}"
      end

      def id_from_graph(form, graph)
        graph.to_s.delete_prefix("#{BASE_URI}#{form.storage}/context/")
      end

      # [label field, companion fields...] for records of this storage: taken
      # from the ontology's own declaration of how OTHER forms display a
      # reference to it (local:references-label + local:label-companion).
      # nil when nothing declares one.
      def label_spec(storage)
        return @label_specs[storage] if @label_specs.key?(storage)

        @label_specs[storage] = Shared.fetch(:label_spec, storage, current_language) do
          declaring = forms.flat_map { |f| fields(f.name) }.find do |fld|
            fld[:references_label] && storage_dbname_for(fld[:references_target]) == storage
          end
          declaring ? [declaring[:references_label], *CBGP::Dataset.label_companions(declaring[:references_target], declaring[:references_label])] : nil
        end
      end

      # A record's human label. Preference: the ontology's declared label
      # fields; failing that, the first two descriptive values the record has
      # (cross-references shown as the record they point to, so a commitment
      # reads "Álvarez, Olga - UI-TEST project").
      def label_for(form_name, raw)
        spec = label_spec(storage_dbname_for(form_name))
        if spec
          parts = spec.map { |qc| Array(raw[qc.to_sym]).join(', ').strip }.reject(&:empty?)
          return parts.join(', ') unless parts.empty?
        end
        descriptive = fields(form_name).reject { |f| Records.date_class?(f) || Records.blank_value?(raw[f[:questionclass].to_sym]) }.first(2)
        descriptive.map { |f| display_value(f, Array(raw[f[:questionclass].to_sym]).first) }.join(' - ')
      end

      # One stored value as a person would read it.
      def display_value(field, value)
        if Records.reference_field?(field)
          ref = resolve_reference(field, value)
          return ref[:label] if ref && ref[:label]
        elsif (label = vocabulary_label(field, value))
          return label
        end
        value.to_s
      end

      # --- cross-references -----------------------------------------------

      # The record a reference field's stored value points to: { form:, id:,
      # label: } or nil when no record holds that value (a dangling key).
      def resolve_reference(field, value)
        key = [field[:references_target], field[:references_via], value.to_s]
        return @references[key] if @references.key?(key)

        @references[key] = lookup_reference(field, value.to_s)
      end

      def lookup_reference(field, value)
        return nil if value.strip.empty?

        target = form!(field[:references_target])
        via = Records.fragment(field[:references_via])
        graph = execute_search(dataset_type: target.storage, search_params: { via => value, "#{via}__exact" => '1' }).first
        return nil unless graph

        build_records(target, [graph]).first&.slice(:form, :id, :label)
      end
      private :lookup_reference

      # --- serialization ----------------------------------------------------

      # Records for graph URIs, in the given order (graphs that hold no record
      # are left out), as plain hashes:
      #   { form:, id:, label:, dates: {field => value}, fields: {field => value},
      #     value_labels: {field => label(s)} }
      # Date-typed fields appear only under dates (so a timeline can be built
      # without knowing field types); blank fields are omitted; value_labels
      # appears only for controlled-vocabulary fields that have a value.
      # Cross-reference values are NOT resolved here (see #references_for).
      def build_records(form, graph_uris, only_fields: nil)
        return [] if graph_uris.empty?

        raw_records = raw_records_for(form, graph_uris)
        stamps = record_stamps(graph_uris)
        by_graph = raw_records.to_h { |raw| [raw[:dataset].to_s, raw] }
        graph_uris.filter_map { |graph| by_graph[graph.to_s] && serialize(form, graph.to_s, by_graph[graph.to_s], stamps[graph.to_s], only_fields) }
      end

      # The two database reads behind build_records, as methods so they can
      # be replaced in a spec.
      def raw_records_for(form, graph_uris)
        fetch_datasets_raw_data(graph_uris: graph_uris, database: form.name)
      end

      # graph URI => the form class that wrote the record (its dcterms:type stamp)
      def record_stamps(graph_uris)
        batch_retrieve_record_forms(graph_uris: graph_uris)
      end

      def serialize(form, graph, raw, stamp, only_fields)
        form_name = stamp || form.name
        defs = fields(form.name)
        wanted = only_fields && only_fields.map(&:to_s)
        dates = {}
        values = {}
        value_labels = {}
        defs.each do |f|
          qc = f[:questionclass]
          value = raw[qc.to_sym]
          next if Records.blank_value?(value) || (wanted && !wanted.include?(qc))

          if Records.date_class?(f) then dates[qc] = value
          else
            values[qc] = value
            labels = Array(value).map { |v| vocabulary_label(f, v) }
            value_labels[qc] = multiple?(f) ? labels : labels.first if controlled_vocabulary_field?(f) && labels.any?
          end
        end
        # A graph that does not exist still comes back from the batched read as
        # a row with nothing in it; a real record always holds a value.
        return nil if dates.empty? && values.empty?

        record = { form: form_name, id: id_from_graph(form, graph), label: label_for(form.name, raw), dates: dates, fields: values }
        record[:value_labels] = value_labels unless value_labels.empty?
        record
      end
      private :serialize

      # { field => [{ value:, label:, form:, id: } | { value:, found: false }] }
      # for every cross-reference field a serialized record has a value for.
      def references_for(form, record)
        fields(form.name).each_with_object({}) do |f, out|
          next unless Records.reference_field?(f)

          values = Array(record[:fields][f[:questionclass]])
          next if values.empty?

          out[f[:questionclass]] = values.map do |v|
            ref = resolve_reference(f, v)
            ref ? { value: v }.merge(ref) : { value: v, found: false }
          end
        end
      end

      # --- search conditions --------------------------------------------------

      # The search engine's parameters for a list of model-supplied
      # conditions: [{ field:, op:, value:, start:, end:, or_empty: }].
      def search_params(form, conditions)
        return {} if conditions.nil? || conditions.empty?
        raise ToolError, "'where' must be a list of conditions like [{\"field\":\"member_name\",\"op\":\"contains\",\"value\":\"maria\"}]." unless conditions.is_a?(Array)

        conditions.each_with_object({}) do |cond, params|
          raise ToolError, "Each condition must be an object with field, op and value. Got: #{cond.inspect}" unless cond.is_a?(Hash)

          field = field!(form, cond['field'])
          qc = field[:questionclass]
          raise ToolError, "Only one condition per field is supported; '#{qc}' appears twice." if params.key?(qc)

          op = (cond['op'] || 'contains').to_s.strip.downcase
          raise ToolError, "Unknown op '#{op}'. Valid ops: #{OPS.keys.join(', ')}." unless OPS.key?(op)

          apply_condition(params, field, op, cond)
          params["#{qc}__orempty"] = '1' if cond['or_empty'] == true
        end
      end

      def apply_condition(params, field, op, cond)
        qc = field[:questionclass]
        if %w[between on_or_after on_or_before].include?(op)
          raise ToolError, "Op '#{op}' needs a date field; #{qc} is #{field[:class]}." unless Records.date_class?(field)

          params[qc] = date_range(qc, op, cond)
          return
        end
        raise ToolError, "Field #{qc} is a date; use op between, on_or_after or on_or_before." if Records.date_class?(field)

        value = cond['value']
        raise ToolError, "Condition on #{qc} needs a non-empty 'value'." if Records.blank_value?(value)

        value = vocabulary_id!(field, value.to_s.strip) if controlled_vocabulary_field?(field)
        params[qc] = value.to_s.strip
        params["#{qc}__exact"] = '1' if %w[equals not_equals].include?(op)
        params["#{qc}__not"] = '1' if %w[not_contains not_equals].include?(op)
      end
      private :apply_condition

      def date_range(qc, op, cond)
        start_at, end_at =
          case op
          when 'on_or_after' then [cond['value'] || cond['start'], nil]
          when 'on_or_before' then [nil, cond['value'] || cond['end']]
          else [cond['start'], cond['end']]
          end
        range = { 'start' => start_at.to_s.strip, 'end' => end_at.to_s.strip }.reject { |_, v| v.empty? }
        raise ToolError, "Date condition on #{qc} needs a date: YYYY-MM-DD, or the word today." if range.empty?

        range.transform_values! { |v| v.casecmp?('hoy') ? 'today' : v } # a Spanish question often arrives as "hoy"
        range.each_value do |v|
          next if v.casecmp?('today') || v.match?(/\A\d{4}-\d{2}-\d{2}\z/)

          raise ToolError, "'#{v}' is not a valid date for #{qc}. Use YYYY-MM-DD or the word today."
        end
        range
      end
      private :date_range
    end
  end
end
