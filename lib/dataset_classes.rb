require_relative 'queries'
require_relative 'core'
require_relative 'ui_text'
require 'uuidtools'
require 'dentaku'
require 'bigdecimal'

module CBGP
  # Represents a single database record of any form type (member, project,
  # publication, …).
  #
  # Each Dataset maps to one named graph in the triple store.  The graph URI
  # follows the pattern:
  #   #{BASE_URI}<form_type>/context/<primary_id>
  #
  # Field definitions are read from the OWL ontology at runtime via SPARQL and
  # cached per (form_type, language) pair.  For each field, a pair of singleton
  # getter/setter methods is defined on the instance so that field values can be
  # accessed by the Ruby method name declared in the ontology (+local:method+).
  #
  # == Cross-reference fields
  # Fields that link to records in another form carry three extra ontology
  # properties (+local:references+, +local:references-via+,
  # +local:references-label+) which drive the typeahead widget in the GUI.
  # The stored value is whatever +references-via+ points to (e.g. an ORCiD),
  # while the typeahead searches and displays using +references-label+ (e.g. a
  # surname).
  #
  # @attr [Array<Hash>] fields field descriptors loaded from the ontology
  # @attr [String] form_type  ontology class fragment identifying this form
  #   (e.g. +"member"+, +"project"+)
  # @attr [String, nil] primary_id  UUID identifying this record; nil until set
  # rubocop:disable Metrics/ClassLength
  class Dataset
    # Raised by .load_from_params_and_write when one or more submitted field
    # values fail coercion/validation (e.g. an unparseable currency amount).
    # Carries every failing field's label + message, not just the first, so
    # the caller can show the user everything that needs fixing in one pass
    # rather than a whack-a-mole of one error per resubmission.
    class ValidationError < StandardError
      attr_reader :errors # Array<{ label:, message: }>

      def initialize(errors:)
        @errors = errors
        super("Validation failed: #{errors.map { |e| "#{e[:label]}: #{e[:message]}" }.join('; ')}")
      end
    end

    # old_values: nil for a new record, or the pre-edit {questionclass_sym =>
    # value} hash for an edit (surfaced from write_dataset_to_db_query, see
    # lib/queries.rb) - transient, never persisted, set once by
    # load_from_params_and_write so CBGP::Triggers.check_and_fire can detect
    # an answer-value transition without a second query.
    attr_accessor :fields, :form_type, :primary_id, :old_values

    @@fields_cache       = {}  # keyed by "form_type_lang"; avoids re-querying the ontology
    @@methods_defined    = {}  # guards against redefining singleton methods per type
    @@primary_key_cache  = {}  # caches the is-primary-id method name per form type

    # Clears every ontology-derived cache (field definitions, primary-id
    # method lookups) so the next request re-queries the freshly-reloaded
    # $ontology instead of serving stale field definitions.
    #
    # Reloading $ontology on its own does NOT invalidate these — they're
    # cached independently, keyed by (form_type, language). Call this
    # whenever $ontology is reloaded (see GET /cbgp/refresh in routes.rb).
    def self.clear_caches!
      @@fields_cache.clear
      @@primary_key_cache.clear
    end

    # The fields every form stored under +dbname+ has in common (same
    # questionclass), in question order. +fields_for(dbname)+ is the UNION of
    # the forms' fields - what cross-references and record loading need - while
    # a search across all of them can only meaningfully offer, and show, what
    # every record has. For a name that is not a shared dbname this is just
    # +fields_for+.
    #
    # @param dbname [String] a storage dbname, e.g. one several forms share
    # @return [Array<Hash>] field descriptors (see +fields_for+)
    def self.common_fields_for(dbname)
      forms = forms_sharing_dbname(dbname: dbname)
      return fields_for(dbname) if forms.size < 2

      shared = forms.map { |form| fields_for(form).map { |f| f[:questionclass] } }.reduce(:&)
      fields_for(dbname).select { |f| shared.include?(f[:questionclass]) }
    end

    # Returns the array of field descriptor hashes for a given form type,
    # building and caching it on first call per (type, language) pair.
    #
    # Each hash contains: +:q+, +:questionclass+, +:label+, +:widget+,
    # +:method+, +:class+, +:cardinality+, +:answers+, +:is_external_primary+,
    # +:sequence+, +:sectionid+, +:sectionlabel+, +:references+,
    # +:references_target+, +:references_via+, +:references_via_method+,
    # +:references_label+ (questionclass fragment of the field shown as an
    # xref's human-readable label, nil if none declared),
    # +:comment+ (mouseover help text, blank if the ontology has none).
    #
    # @param type [String] ontology form fragment, e.g. +"member"+
    # @return [Array<Hash>] field descriptors sorted by +:sequence+
    def self.fields_for(type)
      lang = current_language
      key = "#{type}_#{lang}"

      # fields_for is called constantly (every Dataset field access loops
      # through it), so its debug logging is opt-in only - see
      # CBGP_DEBUG_SPARQL in configuration.md. Dumping the cached fields
      # array on every cache HIT in particular was a real, measurable source
      # of slowness during a bulk load (2026-08-26).
      if ENV['CBGP_DEBUG_SPARQL']
        warn "[CACHE] Checking fields_for(#{type.inspect}) → key=#{key.inspect}, current lang=#{lang.inspect}, thread=#{Thread.current.object_id}"
      end

      if @@fields_cache[key]
        warn "[CACHE] HIT for #{key}" if ENV['CBGP_DEBUG_SPARQL']
        return @@fields_cache[key]
      end

      warn "[CACHE] MISS → building for #{key}" if ENV['CBGP_DEBUG_SPARQL']
      @@fields_cache[key] ||= begin
        fields = []
        sections = get_questionnaire_sections_query(questionnaire_type: type)
        sections.each do |thissection|
          sectionid = thissection[:sec].to_s
          sectionqid = sectionid.gsub(/.*\#/, '')
          sectionlabel = thissection[:label]

          sparql_results = get_section_questions_query(sectionid: sectionqid)
          sparql_results.each do |result|
            q = result[:q].to_s # full URI
            questionclass = q.match(/.*?#(\S+)$/)[1] # fragment
            method_name = result[:method]&.to_s&.to_sym # symbol, safe if nil
            klass = result[:class]&.to_s&.downcase || 'string' # fallback
            # A date-picker field IS a date, whatever class the ontology
            # happens to declare for it (several were declared as string):
            # the value type drives coercion, typed storage (xsd:date, see
            # sparql_literal) and range search, so it must not depend on an
            # ontology editor remembering to set both widget and class.
            klass = 'date' if result[:widget].to_s.split(/[#\/]/).last.to_s.downcase == 'date'
            cardinality = result[:cardinality].to_s
            answers_uri = result[:answers].to_s
            sequence = result[:sequence].to_i
            is_external_primary = result[:primary]&.to_s || 'false'
            references = result[:references]&.to_s # full URI if present
            references_target = result[:references] ? result[:references].to_s.split('#').last : nil # e.g. "member"
            references_via = result[:references_via]&.to_s # e.g. "orcid"   (method name in target)
            references_via_method = result[:references_via] ? result[:references_via].to_s.split('#').last : nil # e.g. "orcid"
            references_label = result[:references_label] ? result[:references_label].to_s.split('#').last : nil # e.g. "member_surnames"

            fields << {
              q: q,
              questionclass: questionclass,
              label: result[:label].to_s,
              widget: result[:widget].to_s.downcase,
              method: method_name,
              class: klass,
              cardinality: cardinality,
              answers: answers_uri,
              is_external_primary: is_external_primary,
              sequence: sequence,
              sectionid: sectionid,
              sectionlabel: sectionlabel,
              references: references, # full URI of the FOrm (e.g. w3id.org/CBGP-App#member)
              references_target: references_target, # just #form
              references_via: references_via,
              references_via_method: references_via_method,
              references_label: references_label, # questionclass shown as the xref's human-readable label
              comment: result[:comment]&.to_s # mouseover help text, current language; blank if the ontology has none
            }
          end
        end
        # One question class can sit in several sections (e.g. project_title
        # is in every project form's section) - harmless for a single form,
        # but when `type` is a shared dbname resolved to several forms' worth
        # of sections (see get_dbname_sections_query), the same field would
        # otherwise be listed once per form.
        fields.uniq! { |f| f[:questionclass] }
        fields.sort_by! { |f| f[:sequence] }
        fields
      end
      @@fields_cache[key]
    end

    def initialize(type:, primary_id: nil)
      @form_type = type
      @primary_id = primary_id
      @data = {}

      # Use cached exact fields (heavy lifting done once per type)
      @fields = self.class.fields_for(type)

      # Initialize storage hash
      @fields.each do |field|
        @data[field[:q]] = (field[:cardinality].downcase == 'multiple' ? [] : nil)
      end

      # Define getters/setters per-instance (fast, reliable)
      @fields.each do |field|
        method_name = field[:method]
        next if method_name.nil? || method_name.to_s.empty? # Guard (with optional debug warn below)

        # Optional debug: warn "Skipping method definition for #{field[:questionclass]} (no :method)" if method_name.nil?

        q = field[:q]
        klass = field[:class]
        cardinality = field[:cardinality]
        answers_uri = field[:answers]

        define_singleton_method(method_name) do
          @data[q]
        end

        define_singleton_method("#{method_name}=") do |value|
          coerced_value = coerce_value(value, klass, cardinality)

          # Standard controlled-vocabulary validation (unchanged)
          validate_value(coerced_value, fetch_answers(answers_uri)) if answers_uri && !answers_uri.end_with?('#FREE')

          @data[q] = coerced_value
        end
      end
    end

    # Pre-fills this (blank) record's cross-reference fields from request
    # params - e.g. ?commitment_member=<NIE> from a member's "add a new
    # commitment" link. Only cross-reference fields, only non-blank values;
    # anything invalid is skipped silently (it's a convenience, not input
    # that is being saved).
    def prefill_references(params)
      fields.each do |field|
        next unless field[:references_target] && field[:method]

        value = params[field[:questionclass]].to_s.strip
        next if value.empty?

        public_send("#{field[:method]}=", field[:cardinality].casecmp('multiple').zero? ? [value] : value)
      rescue ArgumentError
        next
      end
      self
    end

    # Builds a blank Dataset the same way +new+ does, then pre-populates any
    # fields the given form declares a default for (see
    # +get_form_defaults_query+ in lib/queries.rb) — e.g. a hidden
    # discriminator field defaulting to "personnel-project" on one form and
    # "research-project" on another, even though both forms share the same
    # underlying question class.
    #
    # Only meaningful for a genuinely new/blank record — callers that load an
    # existing record (+load_from_primary_id+, +load_from_graph+) should keep
    # using plain +new+, since an existing record's real stored values (or
    # genuine blanks) must never be silently overwritten by a default.
    #
    # @param type [String] dbname used for storage, e.g. "project" - same
    #   meaning as +new+'s +type:+
    # @param form [String] the specific form class, e.g. "personnel_project"
    #   - this is what defaults are looked up by, and is deliberately a
    #   separate parameter from +type:+ since several forms can share one
    #   dbname
    # @return [CBGP::Dataset]
    def self.new_with_defaults(type:, form:)
      dataset = new(type: type)
      defaults = form_default_answers(form: form)
      return dataset if defaults.empty?

      dataset.fields.each do |field|
        raw_default = field[:method] && defaults[field[:questionclass]]
        apply_default_to_field(dataset, field, raw_default) if raw_default
      end
      dataset
    end

    # Coerces+applies one field's default the same way a real submitted value
    # would be coerced, so a default is never treated more leniently than
    # user input. Split out of +new_with_defaults+ purely to keep that
    # method's branching shallow.
    def self.apply_default_to_field(dataset, field, raw_default)
      value_to_coerce = field[:cardinality].to_s.downcase == 'multiple' ? [raw_default] : raw_default
      coerced = dataset.coerce_value(value_to_coerce, field[:class], field[:cardinality])
      return if coerced.nil? || (coerced.is_a?(Array) ? coerced.empty? : coerced.to_s.empty?)

      dataset.public_send("#{field[:method]}=", coerced)
    end
    private_class_method :apply_default_to_field

    # Resolves a form's local:has-defaults branch into a plain
    # +{questionclass => value}+ hash. Split out from +new_with_defaults+ so
    # it's independently callable/testable without needing a Dataset
    # instance.
    #
    # @param form [String] the specific form class, e.g. "personnel_project"
    # @return [Hash{String => String}]
    def self.form_default_answers(form:)
      get_form_defaults_query(form_class: form).each_with_object({}) do |row, hash|
        field_fragment = row[:field].to_s.split('#').last
        hash[field_fragment] = row[:value].to_s
      end
    end

    # Resolves a form's local:requires-field markers into a plain Set of
    # questionclass fragment strings — e.g. +#<Set: {"project_title"}>+.
    #
    # Deliberately parallel in shape to +form_default_answers+ above (same
    # "call the SPARQL query, strip each result URI down to its trailing
    # #fragment" pattern) but returns a Set, not a Hash, because — as
    # explained on local:requires-field in the .owl file — "required" has no
    # second piece of data attached. There's no "value" to look up, only
    # "is this questionclass in the set of fields this form requires?", and
    # a Set answers exactly that question (fast +#include?+, no duplicates)
    # without pretending there's a value where there isn't one.
    #
    # @param form [String] the specific form class, e.g. "personnel_project"
    #   — same caveat as everywhere else in this file: must be the real form
    #   class, not the shared dbname, or every form on that dbname would
    #   appear to share one form's requirements.
    # @return [Set<String>] questionclass fragments this form requires
    def self.form_required_fields(form:)
      get_form_required_fields_query(form_class: form).each_with_object(Set.new) do |row, set|
        set << row[:field].to_s.split('#').last
      end
    end

    # Resolves a form's local:has-conditional-requirements into plain rules, a
    # sibling of +form_required_fields+ for fields that are required only
    # when another field has a given answer. Several answers for one rule are
    # grouped; answers are the stored answer ids (e.g. "Awarded").
    #
    # @param form [String] the specific form class (never the shared dbname -
    #   same caveat as +form_required_fields+)
    # @return [Array<Hash>] +{field:, when_field:, answers: [...]}+ per rule
    def self.form_conditional_requirements(form:)
      grouped = get_form_conditional_requirements_query(form_class: form).each_with_object({}) do |row, rules|
        key = [row[:field].to_s.split('#').last, row[:when_field].to_s.split('#').last]
        (rules[key] ||= []) << row[:answer].to_s.split('#').last
      end
      grouped.map { |(field, when_field), answers| { field: field, when_field: when_field, answers: answers.uniq.sort } }
    end

    # The validation errors for the conditional requirements of +form+ that
    # +dataset+ breaks: a rule applies when the dataset's value for the rule's
    # when-field is one of its answers, and then the field must not be blank.
    # A rule pointing at a field the dataset does not have is ignored, like an
    # unknown requires-field marker.
    def self.conditional_requirement_errors(dataset:, form:)
      form_conditional_requirements(form: form).filter_map do |rule|
        field = dataset.fields.find { |f| f[:questionclass] == rule[:field] }
        when_field = dataset.fields.find { |f| f[:questionclass] == rule[:when_field] }
        next unless field && when_field

        chosen = Array(dataset.public_send(when_field[:method])).map(&:to_s).find { |v| rule[:answers].include?(v) }
        next unless chosen
        next unless blank_field_value?(dataset.public_send(field[:method]))

        { label: field[:label],
          message: ui_text('required.when_error', field: field[:label], when_field: when_field[:label],
                                                  answer: cached_label_for_id(id: chosen) || chosen) }
      end
    end

    # Resolves a form's local:has-formulas branch into a plain
    # +{questionclass => formula_expression}+ hash — a THIRD sibling of
    # +form_default_answers+/+form_required_fields+ above, same "call the
    # SPARQL query, strip URIs to their #fragment" shape as +
    # form_default_answers+ (a formula, like a default, is TWO pieces of
    # data per field: which one, and what — here a Dentaku expression
    # string instead of a literal value).
    #
    # @param form [String] the specific form class, e.g. "project" — same
    #   "must be the real form, never the shared dbname" caveat as its two
    #   siblings.
    # @return [Hash{String => String}] questionclass fragment => Dentaku
    #   expression string, e.g. +{"project_cbgp_overheads" =>
    #   "project_total_funding * 0.13"}+
    def self.form_formulas(form:)
      get_form_formulas_query(form_class: form).each_with_object({}) do |row, hash|
        field_fragment = row[:field].to_s.split('#').last
        hash[field_fragment] = row[:formula].to_s
      end
    end

    # Server-side, AUTHORITATIVE computation of every calculated field this
    # form declares (see local:has-formulas' doc comment in the .owl file
    # for the full design rationale). Called from
    # +load_from_params_and_write+ *after* the ordinary per-field coercion
    # loop, so it always overwrites whatever a calculated field's own
    # widget happened to submit (nothing, in practice — the widget's visible
    # input carries no +name+ attribute, see app/views/_calculated.erb) with
    # a value computed fresh from this submission's other field values.
    # This is what makes the mechanism trustworthy: nothing a user could
    # type or tamper with in the browser ever reaches the database directly
    # for a calculated field — only this method's own output does.
    #
    # == Dependency CHAINS are supported (one calculated field can reference
    #    another)
    # A real example that forced this: "CBGP overheads" = 5% of "UPM
    # overheads", which is itself 25% of Total funding. Dentaku only ever
    # evaluates one flat expression at a time, so a chain like that can't be
    # solved in a single pass — CBGP overheads' formula needs UPM
    # overheads' value, which doesn't exist yet the first time we look.
    #
    # Solved with a straightforward FIXED-POINT ITERATION, not a real
    # dependency graph/topological sort: repeatedly re-attempt whatever
    # calculated fields haven't resolved yet, each pass with the
    # freshly-widened set of already-computed values folded back in as
    # available variables, until either everything resolves or a full pass
    # makes no further progress. Bounded to +formulas.size+ passes — always
    # enough for any acyclic chain (one field resolves per pass, worst
    # case) — so a genuine circular reference (A needs B, needs A) just
    # stops making progress and both stay blank, rather than looping
    # forever. No explicit cycle detection/error for that case (yet) — it
    # fails the same safe, silent way a missing base value does.
    #
    # == Building Dentaku's variable set (each pass)
    # Every OTHER *scalar* (Single-cardinality) field's current value on
    # +dataset+ becomes a Dentaku variable, keyed by its questionclass
    # fragment — exactly the "ontology term ID" an ontology editor already
    # writes formulas in terms of, so no separate ID scheme to learn. This
    # naturally includes any calculated field that resolved in an EARLIER
    # pass (it's no longer "pending", so it's no longer excluded) — that's
    # what makes the chain resolve. Two things are still always excluded:
    # * Multiple-cardinality fields — Dentaku variables must be scalar, and
    #   this codebase does not yet support aggregating an array (e.g.
    #   summing a not-yet-existing yearly-disbursement field) into one.
    # * Calculated fields that HAVEN'T resolved yet this pass — see above.
    #
    # == Error handling
    # A missing/blank dependency (Dentaku::UnboundVariableError) is treated
    # as ordinary, not an error, on any given pass — the calculated field
    # just stays pending and gets retried next pass (or, if nothing ever
    # provides that dependency, stays blank at the end — same as if it had
    # no formula at all). This is the expected, common case (e.g. an
    # overheads formula needs Total funding, but Total funding is optional
    # and was left blank). Anything else Dentaku raises (a malformed
    # formula, division by zero) genuinely means something is wrong and IS
    # surfaced as a friendly error, via the exact same {label:, message:}
    # shape the required-fields pass uses, so it renders in the same error
    # banner — and, unlike an unbound variable, is NOT retried on a later
    # pass (retrying a genuinely malformed formula can't ever succeed).
    #
    # @param dataset [CBGP::Dataset] a dataset whose non-calculated fields
    #   have already been coerced from submitted params
    # @param form [String] the specific form class, e.g. "project"
    # @return [Array<Hash>] any {label:, message:} errors to append to the
    #   caller's own +errors+ array
    def self.evaluate_calculated_fields(dataset:, form:)
      formulas = form_formulas(form: form)
      return [] if formulas.empty?

      # Blank every calculated field BEFORE evaluation starts - not just
      # "for safety", but because the fixed-point loop below relies on
      # "does this field still hold a blank value?" to tell whether a
      # formula has resolved yet. If a calculated field's own widget
      # somehow arrived with a submitted value (it shouldn't — its input
      # has no name attribute — but nothing stops a hand-crafted request),
      # the earlier per-field coercion loop would already have written
      # that value onto +dataset+, and an EARLY pass whose formula isn't
      # resolvable yet (a chained field waiting on another calculated
      # field) would wrongly read that leftover value as "already
      # computed" and stop retrying it — silently keeping a tampered
      # number instead of the real calculation. Clearing first makes
      # "still blank" a trustworthy signal throughout.
      formulas.each_key do |questionclass|
        field = dataset.fields.find { |f| f[:questionclass] == questionclass }
        dataset.public_send("#{field[:method]}=", '') if field
      end

      errors = []
      pending = formulas.dup

      formulas.size.times do
        break if pending.empty?

        resolved_this_pass = resolve_pending_formulas(dataset, pending, errors)
        resolved_this_pass.each { |qc| pending.delete(qc) }
        break if resolved_this_pass.empty? # no progress - remaining are unresolvable (missing data or a cycle)
      end

      errors
    end
    private_class_method :evaluate_calculated_fields

    # Runs one pass over +pending+ (a {questionclass => expression} Hash,
    # mutated by the caller afterward — this method only reads it), trying
    # every formula that hasn't resolved yet against the variable set
    # available RIGHT NOW. Returns the questionclasses that resolved (or
    # errored, or point at a nonexistent/Multiple field) this pass — i.e.
    # everything the caller should stop retrying.
    def self.resolve_pending_formulas(dataset, pending, errors)
      variables = dentaku_variables_for(dataset, exclude: pending.keys.to_set)
      resolved = []

      pending.each do |questionclass, expression|
        field = dataset.fields.find { |f| f[:questionclass] == questionclass }
        if field.nil? || field[:cardinality].to_s.downcase == 'multiple'
          warn "[FORMULA] Skipping #{questionclass}: missing field, or not Single-cardinality" if field
          resolved << questionclass
          next
        end

        error = compute_and_store_formula_field(dataset, field, expression, variables)
        if error
          errors << error
          resolved << questionclass # a real formula error - don't retry, it can't self-correct
        elsif !dataset.public_send(field[:method]).to_s.strip.empty?
          resolved << questionclass # computed successfully
        end
        # else: still unbound this pass - leave it in +pending+ to retry once more values are available
      end
      resolved
    end
    private_class_method :resolve_pending_formulas

    # Builds the Dentaku variable set: every OTHER scalar field's current
    # value on +dataset+, keyed by questionclass fragment. +exclude+ is the
    # set of this form's OWN calculated-field questionclasses — see
    # +evaluate_calculated_fields+'s doc comment for why they're kept out
    # (no chained calculated-on-calculated fields in v1).
    def self.dentaku_variables_for(dataset, exclude:)
      dataset.fields.each_with_object({}) do |field, variables|
        next if field[:method].nil?
        next if field[:cardinality].to_s.downcase == 'multiple'
        next if exclude.include?(field[:questionclass])

        value = dataset.public_send(field[:method])
        variables[field[:questionclass]] = value.to_s unless value.to_s.strip.empty?
      end
    end
    private_class_method :dentaku_variables_for

    # Evaluates one calculated field's formula and writes the coerced
    # result onto +dataset+. Returns nil on success (including the ordinary
    # "a dependency is blank right now" case), or a {label:, message:} error
    # hash if Dentaku raised something other than a missing variable.
    def self.compute_and_store_formula_field(dataset, field, expression, variables)
      result = Dentaku::Calculator.new.evaluate!(expression, variables)

      # A raw arithmetic result (e.g. 15000.50 * 0.13 = 1950.065) can easily
      # land on more decimal places than a currency amount should ever have
      # - coerce_value's currency parser correctly rejects that as not a
      # valid typed amount (it expects money-shaped input, 2 decimals max).
      # Round BEFORE stringifying, not after, so we round the real number
      # rather than truncating its string form.
      result = result.round(2) if field[:class].to_s.downcase == 'currency' && result.respond_to?(:round)

      # Dentaku computes with BigDecimal internally; BigDecimal#to_s (no
      # args) defaults to scientific notation ("0.8e2" for 80.0), which
      # coerce_value's currency parser would also reject. #to_s('F') forces
      # plain fixed-point ("80.0") instead - the form every other numeric
      # string in this codebase is already in.
      result_str = result.is_a?(BigDecimal) ? result.to_s('F') : result.to_s
      reading_canonical_numbers do # the result is canonical ("1950.07"), not typed in the viewer's notation
        coerced = dataset.coerce_value(result_str, field[:class], field[:cardinality])
        dataset.public_send("#{field[:method]}=", coerced)
      end
      nil
    rescue Dentaku::UnboundVariableError
      nil
    rescue Dentaku::Error, ZeroDivisionError, ArgumentError => e
      { label: field[:label], message: "could not be calculated (#{e.message})" }
    end
    private_class_method :compute_and_store_formula_field

    def coerce_value(value, klass, cardinality)
      klass = klass.to_s.downcase
      if value.is_a?(Array) && cardinality.to_s.downcase != 'multiple'
        # A single-valued field handed a list (a page opened while the field was still
        # repeatable, saved after the ontology made it Single). Never store the text of
        # the list - take the one value in it, or refuse if there are several.
        kept = value.map { |v| v.to_s.strip }.reject(&:empty?)
        raise ArgumentError, 'only one value is allowed here' if kept.size > 1

        value = kept.first.to_s
      end
      return '' if value.to_s.strip.empty?

      if cardinality.downcase == 'multiple' && value.is_a?(Array)
        value.map { |v| v.to_s.strip }.reject(&:empty?).each { |v| require_http_url!(v) if klass == 'url' }
      else
        case klass
        when 'string'
          value.to_s.strip
        when 'integer'
          value.to_i
        when 'date'
          Date.parse(value.to_s).strftime('%Y-%m-%d')
        when 'url'
          require_http_url!(value)
          value.to_s.strip
        when 'currency', 'number'
          parse_currency_input(value) or
            raise ArgumentError, "'#{value}' doesn't look like a valid amount (e.g. 1234.56 or 1.234,56)"
        else
          value.to_s.strip
        end
      end
    rescue StandardError => e
      raise ArgumentError, "Invalid value #{value} for type #{klass}: #{e.message}"
    end

    def require_http_url!(value)
      return if valid_http_url?(value)

      raise ArgumentError,
            "'#{value.to_s.strip[0, 80]}' is not a full web address - it must start with http:// or https:// " \
            '(paste the complete link, not just an identifier)'
    end
    private :require_http_url!

    def fetch_answers(answers_uri)
      [] # Stub: replace with SPARQL query if needed
    end

    def validate_value(value, allowed_answers)
      return if allowed_answers.empty?

      if value.is_a?(Array)
        unless value.all? { |v| allowed_answers.include?(v) }
          raise ArgumentError, "Value #{value} must be one of #{allowed_answers}"
        end
      else
        raise ArgumentError, "Value #{value} must be one of #{allowed_answers}" unless allowed_answers.include?(value)
      end
    end

    # Builds a list of typeahead suggestions for a cross-reference field.
    #
    # This method powers the +/cbgp/reference/suggest/:target+ endpoint and
    # supports two distinct modes:
    #
    # * *Standard* (+via_class+ absent): the displayed label and the stored
    #   value are the same field (e.g. an email address field that also serves
    #   as the cross-reference key).
    #
    # * *Cross-reference* (+via_class+ present): the user searches and sees one
    #   field (e.g. surname, controlled by +label_method+) but the value that
    #   gets stored is a different field (e.g. ORCiD, controlled by +via_class+).
    #   Both +via_class+ and +label_method+ are questionclass fragments; they are
    #   resolved to Ruby method names via +resolve_key_method+ before being used
    #   with +public_send+.  The questionclass itself is used unmodified as the
    #   SPARQL search predicate.
    #
    # @param target_form  [String]       form type to search, e.g. +"member"+
    # @param limit        [Integer]      maximum number of suggestions to return
    # @param search_query [String, nil]  partial text from the user; +nil+ or
    #   blank returns up to +limit+ records (broad search)
    # @param via_class    [String, nil]  questionclass of the field whose value
    #   is stored (e.g. +"member_orcid"+); nil means value == label
    # @param label_method [String, nil]  questionclass of the field shown in the
    #   typeahead dropdown (e.g. +"member_surnames"+); falls back to +via_class+
    #   field when nil
    # @return [Array<Hash>] array of +{ value:, label: }+ hashes ready for JSON
    #   serialisation; +value+ is what gets stored, +label+ is what is displayed
    # The questionclasses shown with +questionclass+ when it serves as a
    # cross-reference label (local:label-companion), in question order. Empty
    # for a field with none, and for a name that is not a safe identifier.
    #
    # @param target_form [String] the referenced form/dbname, e.g. +"member"+
    # @param questionclass [String, nil] the label field, e.g. +"member_surnames"+
    # @return [Array<String>] e.g. +["member_name"]+
    def self.label_companions(target_form, questionclass)
      return [] if questionclass.to_s.strip.empty?

      found = get_label_companions_query(questionclass: questionclass).map { |row| row[:companion].to_s.split('#').last }
      order = fields_for(target_form).map { |f| f[:questionclass] }
      found.select { |qc| order.include?(qc) }.sort_by { |qc| order.index(qc) }
    rescue ArgumentError
      []
    end

    # What a referenced record is called in a lookup list or beside a stored
    # value: its label field, then each companion field, comma-separated -
    # e.g. "Alarcón Moreno, Juan". Fields the record has no value for are
    # skipped; with no companions this is exactly the label field as before.
    def self.reference_display_label(record, target_form:, label_questionclass:, label_method:)
      parts = [reference_values(record, label_method) { [] }.join(', ')]
      label_companions(target_form, label_questionclass).each do |companion|
        method = resolve_key_method(target_form, companion)
        next if method.to_s.strip.empty?

        parts << reference_values(record, method) { [] }.join(', ')
      end
      parts.map(&:strip).reject(&:empty?).join(', ')
    end

    def self.fetch_reference_suggestions(target_form:, limit: 100,
                                         search_query: nil, via_class: nil,
                                         label_method: nil)
      return [] unless target_form

      key_method = if via_class && !via_class.to_s.strip.empty?
                     resolve_key_method(target_form, via_class)
                   else
                     key_method_for_form(target_form)
                   end
      return [] if key_method.to_s.strip.empty?

      # label_method is a questionclass fragment used for two distinct purposes:
      #   1. SPARQL search key  — used directly as the predicate type in search_params
      #   2. Ruby public_send   — needs the local:method name, which may differ
      # resolve_key_method handles the questionclass → method name translation.
      search_questionclass = label_method.to_s.strip.empty? ? nil : label_method.to_s.strip
      search_method = if search_questionclass
                        resolved = resolve_key_method(target_form, search_questionclass)
                        resolved.to_s.strip.empty? ? key_method : resolved
                      else
                        key_method
                      end

      warn "[SUGGEST] key_method='#{key_method}', search_questionclass='#{search_questionclass}', search_method='#{search_method}' for #{target_form}"

      broad = search_query.nil? || search_query.strip.empty?

      graphs = execute_search(
        search_params: broad ? {} : { (search_questionclass || key_method) => search_query.strip },
        dataset_type: target_form,
        broad: broad
      ).first(limit)

      graphs.flat_map do |graph_uri|
        ds = CBGP::Dataset.load_from_graph(graph: graph_uri, database: target_form)
        next [] unless ds

        # The key (and the label) may itself be a repeatable field - a project
        # can have several internal codes - whose getter returns an Array. Each
        # key value is its own suggestion; stringifying the Array would store
        # the literal text ["ABC-1"] as the cross-reference.
        keys = reference_values(ds, key_method) { ds.primary_id }
        label = reference_display_label(ds, target_form: target_form, label_questionclass: search_questionclass,
                                            label_method: search_method)
        keys.map { |value| { value: value, label: label.empty? ? value : label } }
      end
    end

    # A record's value(s) for +method+ as an Array of non-blank Strings,
    # whether the field is single or repeatable. The block supplies the
    # fallback when the record has no such method at all.
    def self.reference_values(record, method)
      Array(record.public_send(method)).map { |v| v.to_s.strip }.reject(&:empty?)
    rescue StandardError
      Array(yield).map { |v| v.to_s.strip }.reject(&:empty?)
    end

    # Reverse of #fetch_reference_suggestions: given a value already stored
    # on a cross-reference field (e.g. an ORCiD), finds the matching record
    # and returns its human-readable label. Used to display a name alongside
    # a stored xref value that has no cached label - e.g. re-opening a saved
    # Publication's "CBGP Author(s)" field only ever had the raw ORCiD to
    # show, never the member's name (found 2026-08-26).
    #
    # @param target_form  [String] the cross-referenced form, e.g. +"member"+
    # @param via_class    [String] questionclass of the field the value is
    #   stored against, e.g. +"member_orcid"+
    # @param label_method [String, nil] questionclass of the field to display,
    #   e.g. +"member_surnames"+; falls back to +via_class+'s own field when nil
    # @param value        [String] the stored value to look up, e.g. an ORCiD
    # @return [String, nil] the label, or +nil+ if nothing matched
    def self.fetch_reference_label(target_form:, via_class:, value:, label_method: nil)
      return nil if target_form.to_s.strip.empty? || via_class.to_s.strip.empty? || value.to_s.strip.empty?

      key_method = resolve_key_method(target_form, via_class)
      return nil if key_method.to_s.strip.empty?

      label_questionclass = label_method.to_s.strip
      label_ruby_method = if label_questionclass.empty?
                             key_method
                           else
                             resolved = resolve_key_method(target_form, label_questionclass)
                             resolved.to_s.strip.empty? ? key_method : resolved
                           end

      graph_uri = execute_search(
        search_params: { via_class => value.to_s.strip },
        dataset_type: target_form,
        broad: false
      ).first
      return nil unless graph_uri

      ds = CBGP::Dataset.load_from_graph(graph: graph_uri, database: target_form)
      return nil unless ds

      label = reference_display_label(ds, target_form: target_form, label_questionclass: label_questionclass,
                                          label_method: label_ruby_method)
      label.empty? ? nil : label
    end

    # Resolves a questionclass fragment to the Ruby method name declared in the
    # ontology via +local:method+.
    #
    # This is necessary because the questionclass (used as the SPARQL predicate
    # type, e.g. +"member_orcid"+) and the Ruby method name (used with
    # +public_send+, e.g. +"orcid"+) can differ.  The ontology is the single
    # source of truth for the mapping.
    #
    # Used for both the stored-value field (+via_class+) and the display/search
    # field (+label_method+) in cross-reference typeaheads.
    #
    # @param target_form_fragment [String] form type, e.g. +"member"+ (currently
    #   unused in the query but kept for future scoping)
    # @param via_class_fragment [String] questionclass fragment, e.g.
    #   +"member_orcid"+
    # @return [String, nil] the +local:method+ value, or +nil+ if not found
    def self.resolve_key_method(target_form_fragment, via_class_fragment)
      query = <<~SPARQL
        #{PREFIXES}
        SELECT ?method
        WHERE {
          cbgp:#{via_class_fragment} local:method ?method .
        }
      SPARQL
      results = SPARQL.parse(query).execute($ontology)
      method_name = results.first[:method]&.to_s
      warn "[RESOLVE KEY] For #{target_form_fragment} via #{via_class_fragment} → #{method_name.inspect}"
      method_name
    end

    # Returns the Ruby method name for the field in +form_type+ that is marked
    # +local:is-primary-id true+ in the ontology.  Result is memoised per form
    # type.
    #
    # The primary-id field is the one whose value uniquely identifies a record
    # for external cross-reference lookups (e.g. ORCiD for members).
    #
    # @param form_type [String] ontology form fragment, e.g. +"member"+
    # @return [String, nil] the method name, or +nil+ if no primary field is
    #   declared
    def self.key_method_for_form(form_type)
      @@primary_key_cache[form_type] ||= begin
        sections = get_questionnaire_sections_query(questionnaire_type: form_type)
        sections.each do |sec|
          results = get_section_questions_query(sectionid: sec[:sec].fragment)
          results.each do |res|
            return res[:method].to_s if res[:primary].to_s.downcase == 'true'
          end
        end
        nil
      end
    end

    # Runs the block with numbers read in their canonical form. What is IN the store
    # ("60.00", "1234.56") and what a calculated field produces is always canonical - a
    # point for the decimals, no thousands separators, which is the English notation -
    # whatever language the viewer uses. The field setters parse what a person TYPES, in
    # the viewer's own notation, so without this a Spanish session reads "60.00" as a
    # malformed amount. The viewer's language is put back afterwards, even on an error.
    def self.reading_canonical_numbers
      previous = Thread.current[:language]
      Thread.current[:language] = 'en'
      yield
    ensure
      Thread.current[:language] = previous
    end

    # Copies a record's stored field values (keyed by questionclass symbol) onto +dataset+.
    def self.assign_stored_values(dataset, details)
      reading_canonical_numbers do
        dataset.fields.each do |field|
          next unless field[:method]

          value = details[field[:questionclass].to_sym]
          dataset.public_send("#{field[:method]}=", value) if value
        end
      end
    end
    private_class_method :assign_stored_values

    # Loads a Dataset by its primary_id string, searching across all graphs.
    #
    # @param primary_id [String] the record's primary identifier value
    # @param database   [String] form type, e.g. +"member"+
    # @return [CBGP::Dataset] populated dataset instance
    # @raise [SystemExit] if primary_id is blank or no graph is found
    def self.load_from_primary_id(primary_id:, database:)
      dataset = new(type: database)
      abort 'primary id cannot be empty - load from identifier ' if primary_id.empty?
      dataset.primary_id = primary_id

      graphuri_results = retrieve_dataset_graph_query(primary_id: primary_id)
      abort "can't load record with primary id #{primary_id}" unless graphuri_results && graphuri_results.any?

      graphuri = graphuri_results.first[:g].to_s

      # FIX: Handle new array return from fetch_datasets_raw_data
      details_array = fetch_datasets_raw_data(graph_uris: [graphuri], database: database)
      details = details_array.first || { dataset: graphuri }

      assign_stored_values(dataset, details)

      dataset
    end

    # Loads a Dataset from a known named graph URI.
    #
    # Accepts pre-fetched data to avoid redundant SPARQL round-trips when
    # called in a batch context (e.g. from +fetch_datasets_raw_data+).
    #
    # @param graph                 [String]     full named graph URI
    # @param database              [String]     form type, e.g. +"member"+
    # @param pre_fetched_details   [Hash, nil]  already-retrieved field hash
    #   keyed by questionclass symbol; re-fetched if nil
    # @param pre_fetched_primary_id [String, nil] already-retrieved primary_id;
    #   queried from the graph if nil
    # @return [CBGP::Dataset] populated dataset instance
    # @raise [SystemExit] if the primary_id cannot be determined
    def self.load_from_graph(graph:, database:, pre_fetched_details: nil, pre_fetched_primary_id: nil)
      dataset = new(type: database)

      primary_id = pre_fetched_primary_id || retrieve_dataset_id_from_graph_query(graph: graph)
      abort "Can't retrieve primary id for graph #{graph}" unless primary_id
      dataset.primary_id = primary_id

      # FIX: Handle new array return
      if pre_fetched_details
        details = pre_fetched_details # Already single hash from batch
      else
        details_array = fetch_datasets_raw_data(graph_uris: [graph], database: database)
        details = details_array.first || { dataset: graph }
      end

      # A caller-supplied graph URI that doesn't actually hold this record's
      # data (wrong URI, typo, stale value) must fail loudly here, not
      # produce a validly-shaped but empty Dataset - the only two callers of
      # this method either display it (harmless either way) or write it
      # straight back to the database as a REPLACEMENT for the real
      # record (catastrophic if "empty" silently means "every other field
      # is now gone"). Confirmed live 2026-10-15: exactly this silent
      # failure, caused by a caller passing a subject URI
      # (.../member/dataset/<id>) where the actual named graph
      # (.../member/context/<id>) was needed, destroyed all but one field
      # on 704 real member records before anyone noticed - every one of
      # them "worked" without raising a single error.
      if details.keys.reject { |k| k == :dataset }.empty?
        abort "load_from_graph: graph #{graph} yielded no #{database} field data at all - " \
              'refusing to return an empty-looking Dataset (did you pass a subject URI ' \
              'instead of the actual named graph URI?)'
      end

      assign_stored_values(dataset, details)

      dataset
    end

    # Validates incoming form parameters, writes the dataset, and returns it.
    #
    # This is the single entry point for all HTML form submissions and bulk
    # loaders.  It handles both *new record* and *edit* paths:
    #
    # * *New record*: the form's hidden +primary_id+ field is empty; a fresh
    #   UUID is generated.
    # * *Edit*: the hidden +primary_id+ field carries the existing UUID; the old
    #   named graph is dropped and rewritten with the same UUID, preserving the
    #   graph URI across edits.
    # * *External primary key*: if a field is marked +local:is-primary-id true+
    #   in the ontology, its submitted value is used to look up an existing
    #   record.  If found, that record's UUID becomes the primary_id (triggering
    #   an overwrite rather than a duplicate).
    #
    # primary_id resolution priority:
    #   1. +is_external_primary+ lookup (highest — set during field iteration)
    #   2. Hidden +primary_id+ form param (edit path)
    #   3. Fresh +SecureRandom.uuid+ (new record)
    #
    # Every field is attempted even if an earlier one fails coercion, and all
    # failures are collected into a single +ValidationError+ (rather than
    # raising on the first bad field) so the caller can show the user
    # everything that needs fixing in one pass. Nothing is written to the
    # triple store if any field fails.
    #
    # @param params [Hash] Sinatra params hash from the POST request; must
    #   include +'database'+ (form type) and +'primary_id'+ (may be empty)
    # @return [CBGP::Dataset] the saved dataset instance
    # @raise [ValidationError] if one or more fields fail coercion/validation
    # rubocop:disable Metrics/MethodLength, Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
    # +form:+ is the specific FORM class this submission came from (e.g.
    # "personnel_project"), threaded through from the hidden "form_class"
    # field on dataset.erb/user_dataset.erb - NOT params['database'], which
    # is only the shared dbname/table (e.g. "project") and can't tell two
    # forms sharing one dbname apart. It defaults to params['database'] so
    # that any caller which genuinely has no form/dbname split (a dbname
    # with only one form) keeps working without having to pass anything new.
    def self.load_from_params_and_write(params:, form: nil)
      warn "PARAMS: #{params.inspect}"
      effective_form = form.to_s.strip.empty? ? params['database'] : form
      # type: effective_form (NOT params['database']) - params['database'] is
      # the shared storage dbname (e.g. "project"), which is no longer itself
      # a valid ontology class since Sara's project-fields restructuring
      # split it into several specific forms. Building +dataset+ with the
      # dbname instead of the real form silently defeats BOTH the coercion
      # loop below (dataset.fields ends up empty, so it iterates zero times)
      # AND the required-fields pass further down (every required field's
      # `dataset.fields.find` comes back nil, so every required-field check
      # is silently skipped) - a real, silent data-loss bug found 2026-08-26.
      dataset = CBGP::Dataset.new(type: effective_form)
      errors = []

      dataset.fields.each do |field|
        value = params[field[:questionclass]]
        next unless value
        next if value.empty?

        warn "field #{field[:label]} value #{value}"

        if field[:is_external_primary].downcase == 'true'
          # Look up any existing record with this external identifier so we
          # overwrite it rather than create a duplicate.
          #
          # Searched under the form's storage dbname (where write_dataset_to_db_query
          # puts it), not the form class - several forms can share one dbname, and
          # re-entering an identifier through a sibling form must still find the
          # record. A repeatable primary-id field (e.g. a project's internal code)
          # arrives as an Array: the first value that matches an existing record wins.
          dataset.primary_id = Array(value).map(&:to_s).map(&:strip).reject(&:empty?).lazy.map do |v|
            CBGP::Dataset.get_primary_id(questionclass: field[:questionclass], questionvalue: v,
                                         dataset_type: storage_dbname_for(effective_form))
          end.find { |found| found }
          warn "set primaryid to #{dataset.primary_id.inspect}"
        end

        begin
          coerced_value = dataset.coerce_value(value, field[:class], field[:cardinality])
          if coerced_value && (!coerced_value.is_a?(Array) || !coerced_value.empty?)
            dataset.public_send("#{field[:method]}=", coerced_value)
          end
        rescue ArgumentError => e
          errors << { label: field[:label], message: e.message }
        end
      end

      # Third(-ish) pass: server-side, authoritative computation of every
      # calculated field this form declares (local:has-formulas — see
      # evaluate_calculated_fields' doc comment above for the full design).
      # Deliberately runs BEFORE the required-fields pass below, so that if
      # a calculated field is ever also marked required, it's checked
      # against its just-computed value, not against whatever (nothing) its
      # own read-only widget submitted.
      errors.concat(evaluate_calculated_fields(dataset: dataset, form: effective_form))

      # Second validation pass: form-scoped required fields (local:requires-
      # field, see form_required_fields above). This is deliberately kept
      # SEPARATE from the coercion loop above rather than folded into it,
      # because the two loops check fundamentally different things: the
      # first asks "for each value the user DID submit, is it well-formed?"
      # (iterates dataset.fields); this one asks "for each field THIS FORM
      # requires, did the user submit anything at all?" (iterates
      # form_required_fields(form: ...)). A field can fail either, both, or
      # neither check independently, so keeping them as two passes over two
      # different lists is clearer than trying to interleave them.
      #
      # dataset.fields.each do |field| ... end above already ran
      # coerce_value/public_send for every submitted value, so by this
      # point required fields that WERE submitted already have their
      # coerced value sitting on the dataset object - we just have to ask
      # the dataset for it and see if it's blank.
      form_required_fields(form: effective_form).each do |required_field|
        field = dataset.fields.find { |f| f[:questionclass] == required_field }
        # A required-field marker pointing at a field this dbname doesn't even have - ignore rather than crash.
        next unless field

        current_value = dataset.public_send(field[:method])
        next unless current_value.nil? || (current_value.respond_to?(:empty?) && current_value.empty?)

        errors << { label: field[:label], message: "#{field[:label]} is required" }
      end
      errors.concat(conditional_requirement_errors(dataset: dataset, form: effective_form))

      raise ValidationError.new(errors: errors) if errors.any?

      primary_id_param = params['primary_id'].to_s.strip

      if dataset.primary_id.to_s.strip.empty?
        dataset.primary_id = primary_id_param.empty? ? SecureRandom.uuid : primary_id_param
      end

      oldid = primary_id_param.empty? ? nil : primary_id_param
      # form: effective_form, so the write path stamps dcterms:type with the
      # TRUE form (e.g. "personnel_project"), never the shared dbname - see
      # write_dataset_to_db_query's doc comment in lib/queries.rb.
      write_result = write_dataset_to_db(dataset: dataset, oldid: oldid, form: effective_form)
      # &. : specs that stub write_dataset_to_db without an explicit
      # .and_return get RSpec's default nil, which is fine - old_values
      # simply stays nil, same as a brand-new record.
      dataset.old_values = write_result&.dig(:old_values)
      dataset
    end
    # rubocop:enable Metrics/MethodLength, Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity

    # Builds a Dataset populated with the *raw*, unvalidated values a user
    # just submitted (bypassing coerce_value entirely), so a form can be
    # redisplayed with everything they typed still in place after a
    # ValidationError — instead of losing their work and starting blank.
    #
    # @param type [String] form type, e.g. +"project"+
    # @param params [Hash] the same Sinatra params hash passed to
    #   +load_from_params_and_write+
    # @return [CBGP::Dataset] dataset with raw submitted values, unvalidated
    def self.new_from_raw_params(type:, params:)
      dataset = new(type: type)
      primary_id = params['primary_id'].to_s.strip
      dataset.primary_id = primary_id unless primary_id.empty?

      dataset.fields.each do |field|
        value = params[field[:questionclass]]
        next if value.nil?

        dataset.set_raw(field[:q], value)
      end
      dataset
    end

    # Directly sets a field's underlying storage, bypassing coerce_value and
    # any validation. Only for redisplaying unvalidated user input (see
    # .new_from_raw_params) — never use this for data that will be persisted.
    #
    # @param field_uri [String] full field URI (field[:q])
    # @param value [Object] raw value to store, unvalidated
    def set_raw(field_uri, value)
      @data[field_uri] = value
    end

    # Searches for an existing record whose +questionclass+ field has the given
    # value, and returns its primary_id string.
    #
    # Used by +load_from_params_and_write+ to detect duplicates when a field is
    # marked +local:is-primary-id true+ in the ontology (e.g. ORCiD for members).
    #
    # @param questionclass [String] the ontology questionclass to match against
    # @param questionvalue [String] the value to search for
    # @param dataset_type  [String] form type to scope the search
    # @return [String, nil] primary_id of the matching record, or +nil+ if none
    def self.get_primary_id(questionclass:, questionvalue:, dataset_type:)
      graphuris = execute_search(search_params: { questionclass => questionvalue }, dataset_type: dataset_type) # execute_search(search_params:, dataset_type:)
      warn "Found GraphURIs #{graphuris.inspect}"
      unless graphuris.empty?
        res = retrieve_dataset_id_from_graph_query(graph: graphuris.first) # comes back as a string
        return res
      end
      nil # keeps it empty for the main routine to set it later
    end

    # Persists this instance to the triple store, generating a UUID if the
    # record has no primary_id yet.  Always performs a plain INSERT (no delete
    # of a prior graph).  Use +load_from_params_and_write+ for edit semantics.
    #
    # @return [Object] raw response from the SPARQL update endpoint
    def write_to_db
      warn 'WRITING DATASET TO DB'
      self.primary_id = SecureRandom.uuid unless primary_id
      write_dataset_to_db(dataset: self)
    end

    # Class-level write helper.  Delegates to +write_dataset_to_db+ after
    # ensuring a primary_id exists.  Prefer +load_from_params_and_write+ for
    # form submissions, which handles edit/delete semantics correctly.
    #
    # @param dataset [CBGP::Dataset] the dataset to persist
    # @param oldid   [String, nil]   if supplied, the old graph is dropped first
    # @return [Object] raw response from the SPARQL update endpoint
    def self.write_to_db(dataset:, oldid: nil)
      warn 'WRITING DATASET TO DB'
      dataset.primary_id = SecureRandom.uuid if dataset.primary_id.to_s.strip.empty?
      write_dataset_to_db(dataset: dataset, oldid: oldid)
    end

    # Returns a simplified field list derived from a cached +Questionnaire+
    # object.  Used by older code paths that work with the Questionnaire layer
    # rather than the ontology SPARQL layer directly.
    #
    # @param questionnaire_type [String] questionnaire identifier
    # @return [Array<Hash>] field descriptors sorted by +:sequence+
    def self.get_questionnaire_fields(questionnaire_type:)
      @@fields_cache[questionnaire_type] ||= begin # OPTIMIZATION: Compute once from cached Questionnaire
        questionnaire = Questionnaire.get_cached(questionnaire_type: questionnaire_type)
        fields = []
        questionnaire.sections.each do |section|
          section.questions.each do |question|
            fields << {
              fieldid: question.questionid,
              label: question.question,
              objectmethod: question.objectmethod,
              objectclass: question.objectclass,
              widget: question.widget,
              answerblockid: question.ablockid,
              cardinality: question.cardinality,
              sequence: question.sequence
            }
          end
        end
        fields.sort_by { |f| f[:sequence] }
      end
    end

    # Recursively searches a jstree-style node array for a node whose +'id'+
    # matches +target_id+ and returns its +'text'+ label.
    #
    # @param nodes     [Array<Hash>] tree nodes with +'id'+, +'text'+, and
    #   optional +'children'+ keys
    # @param target_id [String] the node id to locate
    # @return [String, nil] the node's label, or +nil+ if not found
    def self.find_label_by_id(nodes, target_id)
      nodes.each do |node|
        return node['text'] if node['id'] == target_id

        if node['children']&.any?
          found = find_label_by_id(node['children'], target_id)
          return found if found
        end
      end
      nil
    end

    # Flattens a jstree-style node tree into an array of +{ id:, label: }+
    # hashes where each label is the full ancestor path joined with +' → '+.
    # Used to build search-suggestion text for hierarchical controlled
    # vocabularies (e.g. taxonomy, research area).
    #
    # @param nodes  [Array<Hash>] tree nodes (see +find_label_by_id+)
    # @param path   [Array<String>] ancestor labels accumulated during recursion
    # @param result [Array<Hash>]  accumulator; pass +[]+ on initial call
    # @return [Array<Hash>] flat list of +{ id: String, label: String }+
    def self.flatten_with_path(nodes, path = [], result = [])
      nodes.each do |node|
        current_path = path + [node['text']]
        result << { id: node['id'], label: current_path.join(' → ') }
        flatten_with_path(node['children'] || [], current_path, result) if node['children']
      end
      result
    end
  end
  # rubocop:enable Metrics/ClassLength
end
