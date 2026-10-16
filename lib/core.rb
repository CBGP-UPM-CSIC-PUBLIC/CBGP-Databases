require 'pony'
require 'open3'
require 'securerandom'
require 'set'

def get_databases(type: 'Core', language: $language)
  warn 'getting databases'
  types = get_questionnaire_types_query(type: type, language: language) # [{:questionnaire_type=>"https://w3id.org/CBGP-App#add-member", :questionnaire_label=>"Add/Edit Member"}, {:questionnaire_type=>"https://w3id.org/CBGP-App#add-project", :questionnaire_label=>"Add/Edit Project"}, {:questionnaire_type=>"https://w3id.org/CBGP-App#add-publication", :questionnaire_label=>"Add/Edit Publication"}]
  types = types.map { |hash| [hash[:questionnaire_label], hash[:questionnaire_type].match(/.*#(\S+)/)[1]] }
  warn types
  types
end

def generate_questionnaire(questionnaire_type:) # questionnaire_type comes in as code only
  Questionnaire.new(questionnaire_type: questionnaire_type) # questionnaire_type comes in as just the id)
  # warn questionnaire.inspect
end

# --- Searching a storage dbname that several forms share ----------------------
#
# Several forms can store under one dbname (an institute's four project forms
# all store under "project"). The forms differ in their extra fields, but a
# question like "what is running now" does not care which form wrote a record,
# so such a dbname gets its own search entry covering every form on it. It is
# only ever a SEARCH scope: it is not a form, so it is never offered for
# adding data. Nothing here knows any particular dbname.

# True if +name+ is a storage dbname used by more than one form (and is not
# itself a form's name).
def shared_dbname?(name)
  forms = forms_sharing_dbname(dbname: name)
  forms.size > 1 && !forms.include?(name.to_s)
rescue ArgumentError
  false
end

# What the Query list calls the all-forms entry for +dbname+: the ontology's
# text "dbname.<dbname>" if it has one (so the people who maintain the
# ontology word and translate it), otherwise the generic "%{name} (all types)".
def dbname_label(dbname, language: current_language)
  CBGP::UIText.label("dbname.#{dbname}", language) ||
    CBGP::UIText.label("dbname.#{dbname}", 'en') ||
    ui_text('dbname.all_types', language: language, name: dbname)
end

# [[label, dbname], ...] - one all-forms search entry per shared dbname among
# +databases+ (the [[label, form], ...] list get_databases returns).
def shared_dbname_entries(databases, language: current_language)
  databases.map { |_label, form| storage_dbname_for(form) }.uniq
           .select { |dbname| shared_dbname?(dbname) }
           .map { |dbname| [dbname_label(dbname, language: language), dbname] }
end

# --- Curating a record submitted through a user-facing form ------------------
#
# A user-facing form is a cut-down version of the real forms (e.g. a member
# announcing an application): the people who curate it know what kind of
# record it is, the submitter may not. So a record still on a user-facing form
# can be opened under any Core form stored under the same dbname - the edit
# page then shows the same data under that form's fields, and saving re-stamps
# the record with that form. Nothing here knows any particular form.

# [[label, form], ...]: the Core forms +record_form+'s record may be curated
# as - those sharing its dbname - or [] when the record is not on a
# user-facing form (a curated record's form stays fixed).
def curation_targets(record_form)
  return [] if record_form.to_s.strip.empty?

  category = form_category_for(record_form)
  return [] if category.nil? || category == 'Core'

  siblings = forms_sharing_dbname(dbname: storage_dbname_for(record_form))
  get_databases(type: 'Core', language: current_language).select { |_label, form| siblings.include?(form) }
rescue ArgumentError
  []
end

# [[label, shown value], ...]: what +primary_id+'s record holds under
# +from_form+ that +to_form+ has no field for - it would be lost on saving the
# record under +to_form+ (the earlier version stays in the history).
def values_not_carried(from_form:, to_form:, primary_id:)
  target = CBGP::Dataset.fields_for(to_form).map { |f| f[:questionclass] }
  source = CBGP::Dataset.load_from_primary_id(database: from_form, primary_id: primary_id)
  source.fields.reject { |f| target.include?(f[:questionclass]) || f[:method].nil? }.filter_map do |field|
    value = source.public_send(field[:method])
    next if blank_field_value?(value)

    shown = Array(value).map { |v| resolve_display_value(field, v) }.join(', ')
    [field[:label], shown]
  end
end

# The fields a search on +database+ offers and its results table shows: for a
# shared dbname only those every one of its forms has; otherwise the form's own.
def search_fields_for(database)
  shared_dbname?(database) ? CBGP::Dataset.common_fields_for(database) : CBGP::Dataset.fields_for(database)
end

# The questionclasses a search form on +database+ is limited to, or nil for no
# limit (an ordinary form).
def search_field_restriction(database)
  return nil unless shared_dbname?(database)

  CBGP::Dataset.common_fields_for(database).map { |f| f[:questionclass] }.to_set
end

def identifier_type(id: nil)
  doi_regex = %r{^(?:https://doi\.org/|doi:)?(10\.\d{4,}(?:\.\d+)*/[^/]+)$}
  return 'doi', match[1] if match = id.match(doi_regex)

  # Return the canonical DOI (10.NNNN/identifier)

  ['db_entry', id] # Return the original identifier if not a DOI
end

# Matches a properly-formatted amount in each language's number convention:
# either no grouping separator at all (any number of digits), or grouping in
# proper 3-digit clusters; an optional decimal part of exactly 1-2 digits.
# This is deliberately strict — e.g. "2,00.0000" (en) must be *rejected*, not
# silently reinterpreted as 200.00 by stripping the comma and hoping. Without
# this check, parse_currency_input would accept almost any string containing
# digits and at most one '.', regardless of whether the grouping/decimal
# shape actually makes sense as money.
CURRENCY_INPUT_PATTERNS = {
  'en' => /\A-?(?:\d+|\d{1,3}(?:,\d{3})+)(?:\.\d{1,2})?\z/,
  'es' => /\A-?(?:\d+|\d{1,3}(?:\.\d{3})+)(?:,\d{1,2})?\z/
}.freeze

# Parses a currency amount as typed by the user in the given UI language's
# number convention, into the canonical DB form: a plain decimal string,
# '.' separator, no thousands grouping (e.g. "1234.56").
#
#   en: "1,234.56" -> "1234.56"
#   es: "1.234,56" -> "1234.56"
#
# Rejects (returns nil for) input that doesn't actually look like a properly
# formatted amount in that language — e.g. "2,00.0000" (bad grouping *and* a
# nonsensical number of decimal digits) — rather than blindly stripping
# separators and accepting whatever Float() makes of the remainder.
#
# Used by CBGP::Dataset#coerce_value (save path, where an invalid amount
# should raise) and by build_search_query (search path, where an invalid
# amount should just be skipped) — so this returns nil on unparseable input
# rather than raising; callers decide what nil means for them.
#
# @return [String, nil] canonical decimal string, or nil if unparseable/blank
def parse_currency_input(value, language: current_language)
  text = value.to_s.strip
  return nil if text.empty?

  pattern = CURRENCY_INPUT_PATTERNS[language] || CURRENCY_INPUT_PATTERNS['en']
  return nil unless pattern.match?(text)

  normalized = language == 'es' ? text.delete('.').tr(',', '.') : text.delete(',')
  format('%.2f', Float(normalized))
rescue ArgumentError
  nil
end

# Formats a canonical DB decimal string (see parse_currency_input) for
# display/export in the given UI language's number convention.
#
#   en: "1234.56" -> "1,234.56"
#   es: "1234.56" -> "1.234,56"
#
# If value isn't actually in canonical form (e.g. we're redisplaying a user's
# invalid raw input after a ValidationError, or stored data is somehow
# corrupt), it's returned unchanged rather than mangled — so the user always
# sees exactly what they typed when there's something to fix.
#
# @return [String] formatted amount, unchanged input, or '' if value is blank
def format_currency(value, language: current_language)
  text = value.to_s.strip
  return '' if text.empty?

  negative = text.start_with?('-')
  body = text.sub(/\A-/, '')
  return text unless body.match?(/\A\d+(\.\d+)?\z/)

  whole, fraction = body.split('.', 2)
  fraction = (fraction || '00').ljust(2, '0')[0, 2]
  grouped = whole.reverse.gsub(/(\d{3})(?=\d)/, '\1,').reverse

  thousands_sep, decimal_sep = language == 'es' ? ['.', ','] : [',', '.']
  grouped = grouped.tr(',', thousands_sep)

  "#{'-' if negative}#{grouped}#{decimal_sep}#{fraction}"
end

# Answer-block IDs that mean "free entry" rather than "controlled
# vocabulary" — see QuestionnaireAnswerBlock in lib/questionnaire.rb, which
# special-cases the same four IDs for the same reason.
FREE_TEXT_ANSWER_BLOCKS = %w[FREE NUM DATE HIDDEN].freeze

# True if this field's widget is backed by a controlled vocabulary (select,
# radio, checkbox list, or tree-selector) rather than free text/number/date
# entry — i.e. the value actually stored is an ontology class ID (e.g.
# "usa"), not a human-readable string.
def controlled_vocabulary_field?(field)
  ablockid = field[:answers].to_s.split('#').last
  !ablockid.to_s.empty? && !FREE_TEXT_ANSWER_BLOCKS.include?(ablockid)
end

# Memoized wrapper around get_label_for_id (lib/queries.rb) — a search
# results page can call this once per (field, row), so caching avoids
# re-parsing/re-executing the same SPARQL lookup for repeated values (e.g.
# the same country or status appearing across many rows).
LABEL_LOOKUP_CACHE = {} # rubocop:disable Style/MutableConstant -- intentionally mutated as a cache

def cached_label_for_id(id:, language: current_language)
  key = "#{id}_#{language}"
  LABEL_LOOKUP_CACHE.fetch(key) do
    LABEL_LOOKUP_CACHE[key] =
      begin
        get_label_for_id(id: id, language: language)
      rescue ArgumentError
        # get_label_for_id's validate_local_name! guard is a deliberate
        # SPARQL-injection boundary and must stay strict - but a stored
        # value that doesn't look like a valid id (e.g. legacy free text
        # that slipped past an earlier load's controlled-vocabulary check)
        # should just fail to resolve a pretty label, not crash whatever
        # display/summary call asked for one. Caller already falls back to
        # the raw value on nil (see resolve_display_value).
        nil
      end
  end
end

# Resolves a single stored field value for display: currency amounts are
# locale-formatted (see format_currency); controlled-vocabulary values (e.g.
# "usa") are resolved to their current-language rdfs:label (e.g. "United
# States of America"); anything else (free text, dates, ORCiDs, …) is passed
# through unchanged. Falls back to the raw stored value if no label is found
# (e.g. a since-removed ontology class), so a lookup miss never makes data
# disappear from the results.
#
# @param field [Hash] a field descriptor from CBGP::Dataset.fields_for
# @param value [Object] one stored value for that field (not an Array —
#   callers handle Multiple-cardinality fields by mapping this over each one)
# @return [String] the value as it should be displayed/exported
# Parses a user-supplied web address, accepting only a COMPLETE http(s) URL:
# an http or https scheme, a host, no whitespace or control characters
# anywhere, and none of the characters (" < > \\ `) a real copied link never
# contains raw (browsers percent-encode them) but which an attacker would
# need to break out of an HTML attribute. Anything else - a bare identifier
# like HORIZON-CL5-2027-07-D3-26, "www.example.org", javascript:/data:/ftp:
# URLs - is rejected rather than "fixed up": the call is never guessed from an
# identifier. Non-ASCII (IRIs) and the full range of query punctuation
# (? & = , ; [ ] | ( ) etc.) are fine.
#
# @return [URI::HTTP, nil] nil when not an acceptable URL
MAX_URL_LENGTH = 2048
def parse_http_url(value)
  text = value.to_s.strip
  return nil if text.empty? || text.length > MAX_URL_LENGTH
  return nil if text.match?(/[[:space:][:cntrl:]"<>\\`]/)

  uri = URI.parse(URI::DEFAULT_PARSER.escape(text)) # escape only for parsing non-ASCII; the stored text is untouched
  return nil unless uri.is_a?(URI::HTTP) # URI::HTTPS is a subclass; ftp/javascript/data/mailto are not
  return nil if uri.host.to_s.empty?

  uri
rescue URI::InvalidURIError
  nil
end

def valid_http_url?(value)
  !parse_http_url(value).nil?
end

# An <a> for +value+ when it is an acceptable http(s) URL, otherwise just the
# escaped text - so even data that got in some other way (a bulk loader, an
# old record) can never become a javascript: link or inject markup. Opens in
# a new tab without leaking the opener.
def url_link_html(value, text = nil)
  shown = CGI.escapeHTML((text || value).to_s)
  return shown unless valid_http_url?(value)

  %(<a href="#{CGI.escapeHTML(value.to_s.strip)}" target="_blank" rel="noopener noreferrer">#{shown}</a>)
end

# --- Values as search links -------------------------------------------------
#
# Every value shown on a page can be a link, and every link is the same
# thing: an exact-match search for that stored value (GET
# /cbgp/query-dataset/:database?<field>=<value>&<field>__exact=1 - see
# build_search_query). Never a direct link to one record, even when only one
# record would answer: a value like a category or an institution has no single
# record to open, and treating them all alike means one rule, not one route
# per kind of value. The result page then offers the usual VIEW/EDIT link.

# What stays plain text. Prose is not something anybody looks up; numbers,
# amounts and dates are measurements rather than identifiers, and "every
# record with exactly this amount/day" is rarely the question (range searches
# on the search form answer that better). Judged on the widget AND the
# declared class, since some fields have a date widget but a string class.
FREE_TEXT_WIDGETS = %w[textfield].freeze
QUANTITY_WIDGETS = %w[number currency date].freeze
QUANTITY_CLASSES = %w[number currency date integer decimal].freeze

# True if a value of +field+ should be offered as a search link. url-class
# fields are excluded because they already render as real (external) links.
def search_linkable_field?(field)
  return false if field[:class] == 'url'

  widget = field[:widget].to_s.split('#').last
  return false if FREE_TEXT_WIDGETS.include?(widget) || QUANTITY_WIDGETS.include?(widget)

  !QUANTITY_CLASSES.include?(field[:class].to_s)
end

# Which [database, questionclass] a value of +field+ is searched under.
# A cross-reference field stores the key of ANOTHER record (e.g. a member's
# DNI/NIE/PAS), so its value is looked up in the referenced form's key field -
# "find the person this DNI belongs to". Any other field is looked up in the
# database being shown: that is a dbname when the page lists every form sharing
# it, so a project value finds the records of all the project forms.
def search_link_target(field, database)
  target = field[:references_target].to_s
  via = field[:references_via].to_s.split('#').last.to_s
  if !target.empty? && !via.empty? && CBGP::Dataset.fields_for(target).any? { |f| f[:questionclass] == via }
    return [target, via]
  end

  [database, field[:questionclass].to_s]
rescue StandardError
  [database, field[:questionclass].to_s]
end

def search_link_path(database:, questionclass:, value:)
  query = URI.encode_www_form(questionclass.to_s => value.to_s, "#{questionclass}__exact" => '1')
  "/cbgp/query-dataset/#{ERB::Util.url_encode(database.to_s)}?#{query}"
end

# An <a> that searches +database+ for records whose +field+ holds exactly
# +value+, showing +text+ (default: the value). Plain escaped text - never a
# link - for a blank value, a field that is prose, or anything we cannot
# address, so a doubtful case degrades to what the page showed before.
# +title+ is the full untruncated text for the tooltip. +new_window+ opens the
# search in its own tab (used on the edit page, where leaving would lose
# unsaved changes).
def search_link_html(field:, database:, value:, text: nil, title: nil, new_window: false)
  shown = CGI.escapeHTML((text || value).to_s)
  # A value spanning lines is prose whatever its widget says (nobody looks
  # one up), so it is never a link - a backstop for fields the ontology
  # declares as a one-line "text" widget but people fill with paragraphs.
  return shown if value.to_s.strip.empty? || value.to_s.match?(/[\r\n]/) || !search_linkable_field?(field)

  target_db, questionclass = search_link_target(field, database)
  return shown if target_db.to_s.empty? || questionclass.empty?

  tip = title ? %( title="#{CGI.escapeHTML(title.to_s)}") : ''
  window = new_window ? %( target="_blank" rel="noopener noreferrer"#{title ? %( aria-label="#{CGI.escapeHTML(title.to_s)}") : ''}) : ''
  href = CGI.escapeHTML(search_link_path(database: target_db, questionclass: questionclass, value: value))
  %(<a href="#{href}" class="search-link"#{tip}#{window}>#{shown}</a>)
end

# The "find records with this value" arrows shown beside a field's label on
# the edit page: one new-window search link per value the record currently
# STORES (not whatever is being typed - an unsaved value would search for
# something that does not exist yet). +field+ is the record's field
# descriptor; a blank field, a new record, or a field that is not linkable
# yields ''.
def field_search_links_html(field:, database:, values:)
  Array(values).filter_map do |v|
    next if v.to_s.strip.empty?

    link = search_link_html(
      field: field, database: database, value: v, text: "\u2197", new_window: true,
      title: "Find records with #{resolve_display_value(field, v)} (opens in a new window)"
    )
    link if link.start_with?('<a ')
  end.join(' ')
rescue StandardError
  ''
end

# The human-readable name of a record's form ("Personnel Project"), in the
# current language, straight from the ontology's label for the form class;
# "-" for a record that carries no form stamp.
def record_type_label(form)
  return '-' if form.to_s.strip.empty?

  cached_label_for_id(id: form.to_s) || form.to_s
rescue StandardError
  form.to_s
end

# The "Record type" cell: the form's name as a link listing every record of
# that form (a search with no conditions, restricted to the form).
def record_type_link_html(form)
  return CGI.escapeHTML(record_type_label(form)) if form.to_s.strip.empty?

  %(<a href="/cbgp/query-dataset/#{CGI.escapeHTML(ERB::Util.url_encode(form.to_s))}" class="search-link">#{CGI.escapeHTML(record_type_label(form))}</a>)
end

def resolve_display_value(field, value)
  return format_currency(value) if field[:class] == 'currency'
  return value.to_s unless controlled_vocabulary_field?(field)

  cached_label_for_id(id: value) || value.to_s
end

# True if a field value should be treated as "no value" — nil, an empty
# array/string, or a string that's blank once stripped.
def blank_field_value?(value)
  return true if value.nil?
  return value.empty? if value.respond_to?(:empty?)

  value.to_s.strip.empty?
end

# True if two stored field values are the same, ignoring only the order of a
# Multiple-cardinality field's array (re-ordering isn't a real change) and
# treating any blank shape (nil/""/[]) as equal to any other.
def field_values_equal?(old_value, new_value)
  return true if blank_field_value?(old_value) && blank_field_value?(new_value)

  Array(old_value).map(&:to_s).sort == Array(new_value).map(&:to_s).sort
end

# Renders a field value for the change-summary heuristic below: "(none)" for
# blank, otherwise each value through resolve_display_value (so currency and
# controlled-vocabulary values read the same way here as everywhere else).
def display_field_value_or_none(field, value)
  return '(none)' if blank_field_value?(value)

  Array(value).map { |v| resolve_display_value(field, v) }.join(', ')
end

# Builds the SCD Type 2 "history-detail" heuristic: a human-readable, one
# line per changed field summary of what an edit changed, e.g.
# "Total funding: 15,000.00 → 20,000.00; PI ORCiD: (none) → 0000-0001-2345-6789".
# Unchanged fields are omitted entirely. This is a straightforward
# field-by-field diff, not a semantic understanding of the data — good
# enough to see what changed at a glance.
#
# @param fields [Array<Hash>] field descriptors, e.g. dataset.fields
# @param old_values [Hash] questionclass Symbol => prior value, as returned
#   by fetch_datasets_raw_data (lib/queries.rb)
# @param new_dataset [CBGP::Dataset] the dataset with its new values already set
# @return [String] semicolon-separated change summary, or '' if nothing changed
def summarize_field_changes(fields:, old_values:, new_dataset:)
  fields.filter_map do |field|
    next unless field[:method]

    old_value = old_values[field[:questionclass].to_sym]
    new_value = new_dataset.public_send(field[:method])
    next if field_values_equal?(old_value, new_value)

    old_display = display_field_value_or_none(field, old_value)
    new_display = display_field_value_or_none(field, new_value)
    "#{field[:label]}: #{old_display} → #{new_display}"
  end.join('; ')
end

def build_transitive_tree(results, abblockid:)
  abblockid = abblockid.to_s.strip
  if abblockid.empty?
    warn "Warning: abblockid is nil or empty; using default 'root'."
    abblockid = 'root'
  end
  abblockid_uri = "https://w3id.org/CBGP-App##{abblockid}"

  nodes = {}
  children = Hash.new { |h, k| h[k] = [] }

  results.each do |result|
    aid = result[:aid].to_s
    aid_fragment = aid.split('#').last
    parent = result[:parent]&.to_s
    parent_fragment = parent ? parent.split('#').last : nil

    sequence = if result[:sequence]
                 case result[:sequence]
                 when RDF::Literal::Integer, RDF::Literal::Numeric
                   result[:sequence].value.to_i
                 when RDF::Literal
                   result[:sequence].to_s.to_i
                 else
                   0
                 end
               else
                 0
               end

    # Ensure valid id and text
    next unless aid_fragment && result[:label]&.to_s

    nodes[aid] = {
      id: aid_fragment,
      text: result[:label].to_s.gsub('"', '\"').gsub(/[\n\r\t]/, ' '),
      parent: parent_fragment || '#',
      sequence: sequence
    }
    children[parent] << aid if parent
  end

  descendants = Set.new
  queue = [abblockid_uri]
  while (current = queue.shift)
    next unless children[current]

    children[current].each do |child|
      descendants << child
      queue << child
    end
  end

  root_label = get_label_for_id(id: abblockid)
  nodes[abblockid_uri] ||= {
    id: abblockid,
    text: (root_label || abblockid).gsub('"', '\"').gsub(/[\n\r\t]/, ' '),
    parent: '#',
    sequence: 0
  }
  nodes.select! { |aid, _| aid == abblockid_uri || descendants.include?(aid) }

  nodes.each do |aid, node|
    node[:parent] = '#' if node[:parent] == abblockid
  end

  nodes.each_value { |node| node[:children] = [] }
  nodes.each do |aid, node|
    next if node[:parent] == '#'

    parent_node = nodes["https://w3id.org/CBGP-App##{node[:parent]}"]
    parent_node[:children] << node if parent_node
  end

  nodes.values.select { |n| n[:parent] == '#' }.sort_by { |n| n[:sequence] }
  # warn "Tree: #{tree.inspect}"
end

def nest_children(node, nodes)
  node[:children] = nodes.values.select { |n| n[:parent] == node[:id] }
  node[:children].each { |child| nest_children(child, nodes) }
end
