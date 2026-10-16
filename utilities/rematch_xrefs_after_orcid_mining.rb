require 'dotenv'
Dotenv.load(File.expand_path('../.env', __dir__))
require 'require_all'
require_all '../app'

# IMPORTANT - feed this ALL publication DOIs in the batch being worked on,
# never a "zero-xref publications only" pre-filtered list (same reasoning
# as mine_orcids_from_orcid_org.rb and find_missing_personnel_via_orcid.rb -
# a publication can have one author resolved and another still missing an
# ORCID; it must stay in scope until every findable author on it is found).
#
# This script itself used to re-introduce that exact bug even when fed the
# full batch: it only ever wrote cbgp_author_orcids when the field was
# completely EMPTY (`next unless pub.cbgp_author_orcids.to_a.empty?`), so a
# publication with even one already-resolved author silently blocked every
# OTHER author's freshly-mined ORCID from ever being written to it.
# Confirmed live (2026-10-16): mining a 100-DOI batch found 24 new ORCIDs
# for real orcid-less members, and this gate meant 0 of them actually made
# it onto a publication record. Fixed by merging into whatever's already
# there instead of requiring it to start empty.
unless ARGV[0]
  abort 'provide a file of ALL publication DOIs in this batch as ARGV[0] - ' \
        'not a zero-xref-only list, see the file header'
end

member_index = CBGP::Parsers.load_member_index
dois = File.readlines(ARGV[0], chomp: true).map(&:strip).reject(&:empty?)
updated = 0
harvested_count = 0

dois.each do |doi|
  agency = CBGP::Parsers.resolve_doi_registration_agency(doi: doi)
  result = case agency
           when 'DataCite' then CBGP::Parsers.datacite_parser(doi: doi)
           when 'Crossref' then CBGP::Parsers.crossref_parser(doi: doi)
           else { pub: false, authors: [] }
           end
  result = CBGP::Parsers.openaire_parser(doi: doi) unless result[:pub]

  matched_orcids = CBGP::Parsers.match_authors_to_personnel(authors: result[:authors], member_index: member_index)

  # Harvest any self-asserted ORCID this publication's own metadata already
  # carries for a name-matched, ORCID-less member (same policy now live in
  # lib/loaders.rb for every future load). Write it immediately AND patch
  # the in-memory member_index, so a later DOI in this same batch that also
  # credits this person benefits right away instead of using a stale blank.
  harvested = CBGP::Parsers.harvest_orcids_from_authors(authors: result[:authors], member_index: member_index)
  harvested.each do |h|
    member_ds = CBGP::Dataset.load_from_graph(database: 'member', graph: h[:graph],
                                               pre_fetched_primary_id: h[:graph].split('/').last)
    member_ds.orcid = h[:orcid]
    CBGP::Dataset.write_to_db(dataset: member_ds, oldid: member_ds.primary_id)
    puts "HARVESTED #{h[:orcid]} -> #{h[:graph]}"
    harvested_count += 1

    entry = member_index.find { |m| m[:graph] == h[:graph] }
    entry[:orcid] = h[:orcid] if entry
  end
  matched_orcids = (matched_orcids + harvested.map { |h| h[:orcid] }).uniq

  next if matched_orcids.empty?

  graphs = execute_search(search_params: { 'publication_doi' => doi }, dataset_type: 'publication')
  graph = graphs&.first
  next unless graph

  pub = CBGP::Dataset.load_from_graph(graph: graph, database: 'publication',
                                       pre_fetched_primary_id: graph.split('/').last)
  existing = pub.cbgp_author_orcids.to_a
  merged = (existing + matched_orcids).uniq
  next if merged.sort == existing.sort

  pub.cbgp_author_orcids = merged
  CBGP::Dataset.write_to_db(dataset: pub, oldid: pub.primary_id)
  puts "UPDATED #{doi} -> #{merged} (added #{(merged - existing).inspect})"
  updated += 1
end

puts
puts "Done. #{updated} publication(s) got a new cbgp_author xref added " \
     "(#{harvested_count} ORCID(s) harvested from publication metadata along the way)."
