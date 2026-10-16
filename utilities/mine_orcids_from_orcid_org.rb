require 'dotenv'
Dotenv.load(File.expand_path('../.env', __dir__))
require 'require_all'
require_all '../app'

# Closes the "real CBGP co-author, but no ORCID on file" gap identified while
# testing the DOI bulk import against the Scopus list (2026-10-15): of 41
# publications with zero resolved cbgp-author xrefs, several have an author
# who name-matches a real member exactly, just one with no ORCID yet.
#
# The actual search/accept logic lives in lib/orcid_mining.rb (promoted out
# of this script and into CBGP::Parsers on 2026-10-16, once the same
# lookup got wired into the live DOI-load path too) - this script is now a
# thin batch wrapper: find every orcid-less name-matched member across a
# batch of DOIs, call CBGP::Parsers.mine_member_orcid for each, write what
# it finds, and report what it couldn't resolve for manual curation. See
# that file's header for the full trust criterion, the institute-fragment
# word-boundary fix, and why a bare single-letter given-name initial is
# accepted here specifically.
#
# IMPORTANT - feed this ALL publication DOIs in the batch being worked on,
# never a "zero-xref publications only" pre-filtered list. Confirmed live
# (2026-10-16): once ANY author on a publication resolves, that publication
# gets a non-zero xref count and silently drops out of a "zero xref" filter
# from then on - hiding every OTHER author on it, including a real orcid-
# less CBGP member this script exists to find. Its own per-DOI loop already
# does the right thing (checks every author via find_member_by_name,
# regardless of what else is already resolved on that paper) - a
# publication-level xref-count pre-filter is what breaks that, not this
# script's own logic.
CURATION_PATH = '/home/osboxes/Desktop/CBGP Databases/For Curation/orcid_mining_curation.csv'.freeze

def normalize_dni(value)
  value.to_s.strip.upcase.gsub(/[\s-]/, '')
end

# Calls lib/personnel_matcher.rb's actual (private) find_member_by_name via
# send, rather than keeping a local duplicate - a duplicate already drifted
# out of sync once today (missed the 2026-10-15 hyphen fix entirely, which
# only went into the real method), so this script's whole premise - finding
# name matches the ORCID-less gate would otherwise hide - requires it to
# always see exactly what the production matcher sees.
def find_member_by_name(members, given, family)
  CBGP::Parsers.send(:find_member_by_name, members, given, family)
end

# ---- Step 0: own member index with dni + graph (load_member_index doesn't
# carry either, and step 3 needs the graph to write back to) ----
graphs = execute_search(dataset_type: 'member', broad: true) || []
raw = fetch_datasets_raw_data(graph_uris: graphs, database: 'member')
member_index = raw.map do |d|
  { name: d[:member_name], surname: d[:member_surnames], orcid: d[:member_orcid],
    dni: normalize_dni(d[:member_dni_nie_pas]), graph: d[:dataset].to_s }
end

# ---- Step 1: find every (member, authored-DOI) pair with a real name
# match but no ORCID, across every publication in this batch ----
unless ARGV[0]
  abort 'provide a file of ALL publication DOIs in this batch as ARGV[0] - ' \
        'not a zero-xref-only list, see the file header'
end
dois = File.readlines(ARGV[0], chomp: true)

candidates = {} # dni => { given:, surname:, graph: }
dois.each do |doi|
  doi = doi.strip
  next if doi.empty?

  agency = CBGP::Parsers.resolve_doi_registration_agency(doi: doi)
  result = case agency
           when 'DataCite' then CBGP::Parsers.datacite_parser(doi: doi)
           when 'Crossref' then CBGP::Parsers.crossref_parser(doi: doi)
           else { pub: false, authors: [] }
           end
  result = CBGP::Parsers.openaire_parser(doi: doi) unless result[:pub]

  (result[:authors] || []).each do |author|
    member = find_member_by_name(member_index, author[:given], author[:family])
    next unless member
    next unless member[:orcid].to_s.strip.empty?
    next if member[:dni].empty?

    candidates[member[:dni]] ||= { given: member[:name], surname: member[:surname], graph: member[:graph] }
  end
end

puts "#{candidates.size} distinct members matched by name (no ORCID on file) across #{dois.size} zero-xref DOIs."

# ---- Step 2: mine ORCID.org via the shared CBGP::Parsers.mine_member_orcid
# (name + institute double match, see lib/orcid_mining.rb) ----
mined = 0
curated = []
candidates.each do |_dni, info|
  orcid = CBGP::Parsers.mine_member_orcid(given: info[:given], family: info[:surname])

  if orcid
    puts "MINED: #{info[:given]} #{info[:surname]} -> #{orcid}"
    mined += 1
    # write-back happens in step 3 (batched, see below)
    info[:mined_orcid] = orcid
  else
    # Re-derive the raw candidate pool just for the curation report's
    # "how close did this get" numbers - mine_member_orcid itself only
    # returns a confirmed orcid or nil, not its reasoning.
    results = CBGP::Parsers.orcid_search(given: info[:given], family: info[:surname])
    name_matched = results.select { |c| CBGP::Parsers.orcid_candidate_name_matches?(c, info[:given], info[:surname]) }
    strong = name_matched.count { |c| CBGP::Parsers.explicit_cbgp_match?(c) || CBGP::Parsers.broad_umbrella_match?(c) }
    curated << { name: "#{info[:given]} #{info[:surname]}", candidates: results.size, strong_matches: strong }
  end
end

# ---- Step 3: write the mined ORCIDs onto the matching member records ----
candidates.each_value do |info|
  next unless info[:mined_orcid]

  graph = info[:graph]
  ds = CBGP::Dataset.load_from_graph(graph: graph, database: 'member', pre_fetched_primary_id: graph.split('/').last)
  ds.orcid = info[:mined_orcid]
  CBGP::Dataset.write_to_db(dataset: ds, oldid: ds.primary_id)
end

CSV.open(CURATION_PATH, 'w') do |csv|
  csv << %w[name candidates_found strong_double_matches]
  curated.each { |c| csv << [c[:name], c[:candidates], c[:strong_matches]] }
end

puts
puts "Done. #{mined} ORCIDs mined and written (name + institute affiliation both confirmed)."
puts "#{curated.size} unresolved (zero or ambiguous double-matches) - see #{CURATION_PATH}"
