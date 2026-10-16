require 'dotenv'
Dotenv.load(File.expand_path('../.env', __dir__)) # the project root's .env, not a separate utilities/.env copy - avoids config drift like the Virtuoso migration missing this file (2026-08-26)
require 'require_all'
require_all '../app'
require 'date'
require 'set'

abort 'must provide input csv file' unless ARGV[0]

# ARGV[1] (optional): id_CBGP.csv - the institute's own legacy numeric
# member ids, keyed by name (not DNI - it has no DNI column at all). Used
# only to fill in member_cbgp_id for continuity with pre-existing
# ids/webpages/images; never used as the SCD grouping key (see below).
#
# ARGV[2] (optional): activos_export.csv (the DNI/NIE/PAS column of
# usuarios_activos, via the same Python conversion activos_consolidation_
# loader.rb uses) - used ONLY to decide member_status for each person's
# current version here (active -> left unset, since activos_consolidation_
# loader.rb immediately overwrites that person's current record with the
# authoritative snapshot anyway; not-active -> 'historical'). Deliberately
# set as part of THIS write, not a later patch pass: a prior session
# (2026-10-15) ran that status fix as a separate "load the existing record,
# change one field, write it back" pass, and a graph-URI mistake in that
# pass silently wiped every other field on all 704 non-active records -
# recovered from history afterward, but the real fix is to never need that
# kind of patch pass in the first place. See [[project_doi_xref_gap_closing]].

# a dataset has #fields which is a sequence-ordered list of
# @fields << { q: q, questionclass: questionclass, label: result[:label].to_s,
#  widget: result[:widget].to_s.downcase, method: method_name,
#  class: klass, cardinality: cardinality, answers: answers_uri,
#  is_external_primary: is_external_primary, sequence: sequence,
#  sectionid: sectionid, sectionlabel: sectionlabel }
#
# ds also has getter and setter methods for each method_name
# Sara has set the value of each spreadsheet cell to match the classname!  Thank you!!
#
# CSV headers are the ontology's questionclass fragments (e.g. "member_name",
# not the Dataset setter method "name") - resolved below via fields_for
# rather than assumed to already be method names, since Sara's exports use
# the questionclass form. A couple of headers don't match a questionclass
# exactly (a stray singular/plural, most likely just how the export was
# typed) - HEADER_ALIASES covers those known cases explicitly rather than
# guessing with a fuzzy match.
HEADER_ALIASES = {
  'member_surname' => 'member_surnames',
  'member_orcids' => 'member_orcid'
}.freeze

# One-off bulk history load (2026-09-28): unlike a normal form submission,
# each real person in this export has MULTIPLE rows - one per historical
# "stint" (a contract period, a status change, etc.) - meant to become a
# genuine SCD Type 2 version history for that one person, not N disconnected
# records. Grouped by member_cbgp_id (added to this export by a separate
# CBGP-ID merge pass, see the CBGP Databases desktop folder) - NOT the
# ontology's own primary_id, which is a fresh UUID this script mints once per
# real person and reuses across all of their row-versions.
#
# We can't know the TRUE date each row was originally entered into the old
# system, so every version written here gets today's transaction timestamp
# (dcterms:created/modified) - that's fine, and doesn't need any code
# changes, since write_dataset_to_db_query already always stamps "now".
# What DOES matter, since every transaction timestamp will be ~today, is the
# ORDER we submit the writes in for a given person: that's what the History
# DB will treat as "what happened when", not any date field. So:
#   1. Fix known data-entry errors: some rows have member_start_date and
#      member_end_date entered backwards (confirmed real, ~14% of rows) -
#      swap them whenever end < start, BEFORE sorting, so the correction
#      also fixes the ordering.
#   2. Sort each person's rows by (corrected start, corrected end) ascending
#      - the file's own row order is not trusted to already be chronological
#      (confirmed: sorting by start date alone reorders many people's rows
#      relative to file order). A blank end (still-ongoing) sorts last
#      among any tied start dates.
#   3. Write the ordered rows for each person under ONE reused primary_id -
#      the first write is a plain create (oldid: nil), every subsequent
#      write passes oldid: that same primary_id, so it supersedes the
#      previous version via the normal SCD history mechanism
#      (write_dataset_to_db_query) instead of creating an unrelated record.
member_fields = CBGP::Dataset.fields_for('member')

def method_for_header(field, member_fields)
  questionclass = HEADER_ALIASES.fetch(field, field)
  member_fields.find { |f| f[:questionclass] == questionclass }&.dig(:method)
end

# widget-type is a full URI (e.g. "https://w3id.org/CBGP-App#date") - only
# the fragment matters here.
def date_field?(header, member_fields)
  questionclass = HEADER_ALIASES.fetch(header, header)
  field = member_fields.find { |f| f[:questionclass] == questionclass }
  field && field[:widget].to_s.split('#').last == 'date'
end

# This export's dates are DD/MM/YYYY (confirmed: values like "31/12/2012"
# appear, which is only valid as day/month). Stored fields are class
# "string" (not xsd:date), but validate_date!/build_search_query's date-range
# search both expect YYYY-MM-DD - convert here so this data behaves like any
# real form submission (an HTML date-picker always submits YYYY-MM-DD).
def parse_export_date(value)
  value = value.to_s.strip
  return nil if value.empty?

  Date.strptime(value, '%d/%m/%Y')
rescue ArgumentError
  warn "  WARNING: could not parse date '#{value}' as DD/MM/YYYY - leaving that field blank"
  nil
end

# Real, formal ontology answer ids for a controlled-vocabulary field's
# answer block (radio/hiddenfield/treeselector - see
# controlled_vocabulary_field?, lib/core.rb), fetched once per distinct
# block and cached. Some of this export's values are informal group/lab
# descriptions rather than a real answer id (e.g. "Lab Group 3/Legacy note:
# Phytopathogenic bacteria" for member_research_area_group) - genuinely not
# yet in the ontology's tree, not a parsing bug - see MISSED_VALUES below.
# rubocop:disable Style/MutableConstant -- both intentionally mutated caches/accumulators
VALID_ANSWER_IDS_CACHE = {}

def valid_answer_ids_for(field)
  ablockid = field[:answers].to_s.split('#').last
  VALID_ANSWER_IDS_CACHE[ablockid] ||= begin
    # rdfs:subClassOf+ (transitive property path), not get_answer_block_query
    # (only direct/one-level subclasses) - member_category and
    # member_research_area_group are TREESELECTOR fields with a real
    # multi-level hierarchy, so a real leaf answer (e.g.
    # "project_funded_ptgas") is several rdfs:subClassOf hops below the
    # block root, not a direct child of it. Using the shallow query here
    # would have flagged nearly every genuinely valid value across both
    # fields as "missing from the ontology" - not a real gap, a validation
    # bug. + works uniformly for a flat (single-level) block too.
    q = <<~SPARQL
      #{PREFIXES}
      SELECT DISTINCT ?aid WHERE { ?aid rdfs:subClassOf+ cbgp:#{ablockid} . }
    SPARQL
    SPARQL.parse(q).execute($ontology).map { |row| row[:aid].to_s.split('#').last }.to_set
  end
end

# Rows accumulated here get written to a "*_missed.csv" report at the end -
# every non-blank controlled-vocabulary value that doesn't match a real
# ontology answer id, for Sara to review and decide whether to add as a new
# formal answer later (not something this one-off script should guess at
# inventing itself). Distinct from a blank/"-" cell (silently skipped, see
# below), which just means "no value given", not "value not yet in the
# ontology".
MISSED_VALUES = []
# rubocop:enable Style/MutableConstant

# A handful of Sara's export values are a genuine language gap, not just
# formatting - confirmed live 2026-10-15 for exactly this one case ("Corea
# del Sur" is Spanish for South Korea; the real ontology id is
# "southkorea"). Kept as an explicit, verified, one-at-a-time list rather
# than attempted machine translation - each entry here was individually
# confirmed to resolve to a real ontology answer id before being added.
ANSWER_VALUE_ALIASES = {
  'Corea del Sur' => 'southkorea'
}.freeze

# Sara's export sometimes differs from the real ontology id only by case or
# underscore-vs-hyphen punctuation (e.g. "Mexico" for the real "mexico",
# "ra_none" for the real "ra-none") - confirmed live 2026-10-15 this
# accounts for the large majority of what a naive exact-match check flags
# as "missing from the ontology", not genuine gaps. unaccent is NOT applied
# here (unlike name/surname matching elsewhere) - an ontology answer id is
# a controlled code, not natural-language text, so an actual accent
# difference would be a real typo worth seeing, not something to paper over.
def normalize_answer_candidate(value)
  value.to_s.strip.downcase.tr('_', '-')
end

# Resolves a controlled-vocabulary field's raw export value to a real
# ontology answer id, trying (in order): the value as-is, a case/punctuation-
# normalized match, then the explicit ANSWER_VALUE_ALIASES list. Returns the
# resolved id (ontology-correct, not necessarily the original string) for a
# controlled-vocabulary field, the original value unchanged for any other
# field, or nil (and logs to MISSED_VALUES) when nothing resolves - the
# caller should skip setting the field in that case.
def resolve_controlled_vocabulary_value(person_key:, primary_id:, field:, value:, member_fields:)
  questionclass = HEADER_ALIASES.fetch(field, field)
  field_def = member_fields.find { |f| f[:questionclass] == questionclass }
  return value unless controlled_vocabulary_field?(field_def)

  stripped = value.strip
  valid_ids = valid_answer_ids_for(field_def)
  return stripped if valid_ids.include?(stripped)

  normalized_target = normalize_answer_candidate(stripped)
  normalized_match = valid_ids.find { |id| normalize_answer_candidate(id) == normalized_target }
  return normalized_match if normalized_match

  aliased = ANSWER_VALUE_ALIASES[stripped]
  return aliased if aliased && valid_ids.include?(aliased)

  MISSED_VALUES << { person_key: person_key, primary_id: primary_id, questionclass: questionclass, value: stripped }
  warn "  MISSED: person=#{person_key} #{questionclass}=#{stripped.inspect} is not a real " \
       "#{field_def[:answers].to_s.split('#').last} answer id - logged, not written"
  nil
end

# Sara's export tool doesn't always save UTF-8 (seen: ISO-8859-1, likely a
# Windows/Excel default under a Spanish locale) - detect rather than assume.
# col_sep is ';', not CSV's default ',' - this export uses semicolons
# throughout (same Spanish-locale Excel habit: ',' is the decimal separator
# there, so list exports use ';'). Without col_sep set explicitly, Ruby's
# CSV parser still scans for the default comma and desyncs its quote-state
# tracking on this file's multi-line quoted comment fields, surfacing as a
# misleading "Illegal quoting" error that has nothing to do with the quotes
# themselves (confirmed: Python's csv module parses the same bytes cleanly
# once told the real delimiter).
def read_csv_robustly(path)
  CSV.read(path, headers: true, col_sep: ';')
rescue CSV::InvalidEncodingError
  CSV.read(path, headers: true, col_sep: ';', encoding: 'ISO-8859-1:UTF-8')
end

# Grouping identity: normalized national id (DNI/NIE/passport), not
# member_cbgp_id. A fresh raw export from Sara does NOT have member_cbgp_id
# pre-populated (only a prior hand-merged file did, see memory) - it's
# blank for nearly every row. member_dni_nie_pas is ~99.5% populated and is
# what actually identifies "the same person" across their own history rows,
# even when their name is spelled differently from one row to the next
# (confirmed real: "Makarovsky Saavedra" vs "Makarowsky", same DNI).
def normalize_dni(value)
  value.to_s.strip.upcase.gsub(/[\s-]/, '')
end

# This export's own placeholder DNIs ('-', blank, all-one-character strings
# like "XXXXXX"/"XXXXXXXX") are NOT a shared identity - several different
# real people share the same placeholder, so each such row must be its own
# singleton "person", never merged with the others just because they share
# the placeholder. A genuine NIE legitimately starts with X/Y/Z (e.g.
# "X3625323V") - only an all-same-character value is a placeholder.
def placeholder_dni?(dni)
  dni.empty? || dni.chars.uniq.size <= 1
end

# Accent/case/whitespace-normalized "given surname" key, for matching a
# person against id_CBGP.csv's name-keyed legacy ids. unaccent is
# lib/queries.rb's existing helper (already loaded via require_all '../app'
# above) - reused rather than reimplemented.
def normalize_person_name(given, surname)
  unaccent("#{given} #{surname}").downcase.gsub(/[.-]/, ' ').gsub(/\s+/, ' ').strip
end

id_name_to_ids = Hash.new { |h, k| h[k] = Set.new }
if ARGV[1]
  CSV.foreach(ARGV[1], headers: true) do |r|
    next if r['member_cbgp_id'].to_s.strip.empty?

    key = normalize_person_name(r['member_name'], r['member_surnames'])
    id_name_to_ids[key] << r['member_cbgp_id'].strip
  end
end

activos_dnis = Set.new
if ARGV[2]
  CSV.foreach(ARGV[2], headers: true) do |r|
    activos_dnis << normalize_dni(r['DNI/NIE/PAS'])
  end
end

# Rows accumulated here get written to a "*_needs_cbgp_id_curation.csv"
# report at the end: every person who didn't resolve to exactly one real
# legacy id from id_CBGP.csv. Per explicit user decision (2026-10-15): such
# a person's record and history still load normally (member_cbgp_id is a
# display/continuity attribute, not the SCD identity, and never blocks a
# load) - they just don't get a made-up number. An admin reviews this
# report later and assigns a real id by hand if one exists.
# rubocop:disable Style/MutableConstant -- intentionally mutated accumulator
NEEDS_CURATION = []
# Rows accumulated here get written to a "*_status_anomalies_curation.csv"
# report: a non-activos person whose own change-log data conflicts with
# "absent from activos = historical" (it already says active, or never
# recorded an end date). Left with no status at all rather than guessed in
# either direction - see the write loop below for the full reasoning.
STATUS_ANOMALIES = []
# rubocop:enable Style/MutableConstant

rows = read_csv_robustly(ARGV[0]).map(&:to_h)

by_person = {}
rows.each_with_index do |r, i|
  dni = normalize_dni(r['member_dni_nie_pas'])
  key = placeholder_dni?(dni) ? "__no_dni_row#{i}__" : dni
  (by_person[key] ||= []) << r
end

swap_count = 0
person_count = 0
version_count = 0

by_person.each do |dni_key, person_rows|
  # Resolve this person's legacy member_cbgp_id, trying every name variant
  # seen across their own rows (spelling drift across a person's history is
  # exactly what DNI-grouping exists to paper over - the match should too).
  name_variants = person_rows.map { |r| normalize_person_name(r['member_name'], r['member_surnames']) }.uniq
  found_ids = name_variants.each_with_object(Set.new) { |nv, acc| acc.merge(id_name_to_ids[nv]) }
  resolved_cbgp_id =
    if found_ids.size == 1
      found_ids.first
    else
      NEEDS_CURATION << { dni_key: dni_key, names: name_variants.join('; '),
                           candidate_ids: found_ids.to_a.join(',') }
      nil
    end
  person_rows.each { |r| r['member_cbgp_id'] = resolved_cbgp_id.to_s }
  # Step 1: fix inverted start/end, on the raw row hash, before sorting.
  corrected_rows = person_rows.map do |row|
    row = row.dup
    start_date = parse_export_date(row['member_start_date'])
    end_date = parse_export_date(row['member_end_date'])
    if start_date && end_date && end_date < start_date
      row['member_start_date'], row['member_end_date'] = row['member_end_date'], row['member_start_date']
      swap_count += 1
      warn "  fixed inverted start/end for person=#{dni_key} (was #{end_date} - #{start_date})"
    end
    row
  end

  # Step 2: most-likely-real chronological order. A blank/unparseable end
  # date (still-ongoing) sorts after any real date at the same start.
  far_future = Date.new(9999, 12, 31)
  ordered_rows = corrected_rows.sort_by do |row|
    [parse_export_date(row['member_start_date']) || far_future,
     parse_export_date(row['member_end_date']) || far_future]
  end

  primary_id = SecureRandom.uuid
  person_count += 1
  puts "person=#{dni_key} (cbgp_id=#{resolved_cbgp_id || 'none yet'}): " \
       "#{ordered_rows.size} version(s) -> primary_id=#{primary_id}"

  ordered_rows.each_with_index do |row, index|
    ds = CBGP::Dataset.new(type: 'member')
    ds.primary_id = primary_id

    row.each do |field, value|
      next if field.to_s =~ /DISCARD/
      next if field == 'member_status' # set explicitly below, not from the raw export column
      # "-" is this export's own placeholder for "no value" (seen elsewhere
      # in the same export, e.g. a blank phone number) - harmless if left as
      # literal text in a free-text field, but crashes write_dataset_to_db_query's
      # history-diff summary for a controlled-vocabulary field, which tries
      # to resolve it as an answer-class id. Treat it as blank everywhere,
      # same as a genuinely empty cell.
      next if value.to_s.strip.empty? || value.to_s.strip == '-'

      method_name = method_for_header(field, member_fields)
      abort "Dataset does not have a 'member' field matching CSV header '#{field}'" unless method_name

      resolved_value = resolve_controlled_vocabulary_value(person_key: dni_key, primary_id: primary_id, field: field,
                                                            value: value, member_fields: member_fields)
      next if resolved_value.nil?

      value = resolved_value

      if date_field?(field, member_fields)
        parsed = parse_export_date(value)
        next unless parsed

        value = parsed.iso8601
      end

      ds.public_send("#{method_name}=", value)
    end

    # Set status on this person's LAST (current) version only - a history
    # version just represents "what was true at that point", not a status
    # judgement. Active people get nothing here (activos_consolidation_
    # loader.rb overwrites this same current record with the authoritative
    # snapshot + status=active immediately after this script finishes);
    # everyone else gets 'historical' directly, as part of this one write -
    # no separate patch pass needed at all.
    #
    # Absence from activos is only trusted as "definitely historical" when
    # the person's OWN last change-log row agrees - if that row itself
    # already says active, or never recorded an end date at all (reads as
    # "still ongoing" on its own terms), that's a genuine conflict between
    # two real signals and gets curated, not silently overridden in either
    # direction (same rule the 2026-10-15 sanity check used by hand).
    if index == ordered_rows.size - 1 && !activos_dnis.include?(dni_key)
      source_says_active = row['member_status'].to_s.strip == 'active'
      no_end_date_recorded = parse_export_date(row['member_end_date']).nil?

      if source_says_active || no_end_date_recorded
        reason = if source_says_active
                   'source says active but absent from activos'
                 else
                   'no end_date recorded but absent from activos'
                 end
        STATUS_ANOMALIES << { person_key: dni_key, primary_id: primary_id, reason: reason }
      else
        ds.status = 'historical'
      end
    end

    oldid = index.zero? ? nil : primary_id
    CBGP::Dataset.write_to_db(dataset: ds, oldid: oldid)
    version_count += 1
  end
end

missed_path = "#{ARGV[0].sub(/\.csv\z/i, '')}_missed.csv"
CSV.open(missed_path, 'w') do |csv|
  csv << %w[person_key primary_id questionclass value]
  MISSED_VALUES.each { |m| csv << [m[:person_key], m[:primary_id], m[:questionclass], m[:value]] }
end

curation_path = "#{ARGV[0].sub(/\.csv\z/i, '')}_needs_cbgp_id_curation.csv"
CSV.open(curation_path, 'w') do |csv|
  csv << %w[dni_key names candidate_ids]
  NEEDS_CURATION.each { |c| csv << [c[:dni_key], c[:names], c[:candidate_ids]] }
end

status_curation_path = "#{ARGV[0].sub(/\.csv\z/i, '')}_status_anomalies_curation.csv"
CSV.open(status_curation_path, 'w') do |csv|
  csv << %w[person_key primary_id reason]
  STATUS_ANOMALIES.each { |a| csv << [a[:person_key], a[:primary_id], a[:reason]] }
end

puts
puts "Done. #{person_count} people, #{version_count} record-versions written, " \
     "#{swap_count} inverted start/end pairs corrected."
puts "#{MISSED_VALUES.size} controlled-vocabulary value(s) didn't match a real ontology answer id - see #{missed_path}"
puts "#{NEEDS_CURATION.size} people did not resolve to exactly one real id_CBGP.csv id (loaded " \
     "without member_cbgp_id) - see #{curation_path}"
puts "#{STATUS_ANOMALIES.size} non-activos people had a conflicting status signal of their own (loaded " \
     "without member_status) - see #{status_curation_path}"

# =============================================================================
# MANUAL HISTORY INJECTION - not part of the load above, never called by it.
# Preserved 2026-09-29 after verifying it live (created a throwaway test
# record, injected a fabricated 2015-dated snapshot between two real
# versions, confirmed Dataset#full_timeline sorted it into the correct
# position, then deleted the whole test record - no residue). Kept here in
# case a genuinely backdated event is ever needed later - HIGHLY unlikely
# ("it's fine if we do these injections completely manually... they may
# never be needed"), but cheap to keep now that it's built and tested.
#
# This bypasses the normal write path entirely: no validation, no
# calculated fields, no touching the live/current record - it only adds one
# more item to that record's PAST by hand-writing a snapshot graph straight
# into HISTORY_DATABASE, exactly the same shape write_dataset_to_db_query's
# normal history-capture produces, just with a caller-chosen timestamp
# instead of "now". Use only when the true field values and a true
# (approximate) date for the missing event are actually known.
#
# HOW TIMESTAMP ORDERING WORKS: full_timeline sorts a record's versions by
# plain STRING comparison of generated_at, not a fixed-width sequence - so
# there's no real limit on "room" between two existing timestamps. `at:` just
# has to sort correctly between its intended neighbors; call full_timeline
# first to see their exact generated_at values before picking one.
#
# Example (run manually, in irb/a scratch script - not invoked by this file):
#
#   inject_historical_event(
#     form_type: 'member',
#     primary_id: 'the-existing-record-uuid',
#     field_values: { 'member_category' => 'ramon_y_cajal_researcher', 'member_start_date' => '2015-06-15' },
#     at: '2015-06-15T00:00:00.000000Z',
#     detail: 'Reconstructed from an old paper contract found in 2026 - see email thread with Sara, 2026-09-29.'
#   )
#
# @param form_type [String] e.g. "member" - the dataset type
# @param primary_id [String] the EXISTING record's primary_id to inject a
#   past version for (the record must already exist, current or history)
# @param field_values [Hash{String=>String,Array}] questionclass => value
#   (or an Array of values for a Multiple-cardinality field). Typically a
#   full copy of "what the record looked like" at the fabricated date, not
#   just the one field that changed - a real snapshot captures every field.
# @param at [String] the fabricated ISO8601 timestamp (any precision) this
#   snapshot should sort by
# @param reason [String] short label, stored as local:history-reason
# @param detail [String] free-text explanation for anyone reading
#   local:history-detail later - always say why this was hand-inserted
# @return [String] the new history snapshot's graph URI
def inject_historical_event(form_type:, primary_id:, field_values:, at:, reason: 'manually-injected',
                            detail: 'Backdated event inserted directly, outside the normal write path.')
  fields = CBGP::Dataset.fields_for(form_type)
  graph = "#{BASE_URI}#{form_type}/history/#{primary_id}/#{SecureRandom.uuid}"
  subject = "<#{BASE_URI}#{form_type}/dataset/#{primary_id}>"

  triples = ["#{subject} rdf:type sio:SIO_000089 ;", "  rdf:type cbgp:#{form_type} ."]

  field_values.each do |questionclass, value|
    field = fields.find { |f| f[:questionclass] == questionclass.to_s }
    raise ArgumentError, "no #{form_type} field matches questionclass #{questionclass.inspect}" unless field

    Array(value).each_with_index do |v, index|
      next if v.to_s.strip.empty?

      attr = "<#{graph}#attr_#{questionclass}_#{index}>"
      triples << "#{subject} sio:SIO_000008 #{attr} ."
      triples << "#{attr} rdf:type cbgp:#{questionclass} ."
      triples << "#{attr} sio:SIO_000300 #{sparql_literal(v, field[:class])} ."
    end
  end

  query = <<~SPARQL
    #{PREFIXES}
    PREFIX prov: <http://www.w3.org/ns/prov#>
    INSERT DATA {
      GRAPH <#{graph}> {
        #{triples.join("\n        ")}
        <#{graph}> prov:generatedAtTime "#{at}"^^xsd:dateTime ;
                    local:history-reason "#{escape_for_literal(reason)}" ;
                    local:history-detail "#{escape_for_literal(detail)}" .
      }
    }
  SPARQL

  HISTORY_DATABASE_UPDATE.update(query)
  graph
end
