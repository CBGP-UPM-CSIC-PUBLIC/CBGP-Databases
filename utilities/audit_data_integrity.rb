require 'dotenv'
Dotenv.load(File.expand_path('../.env', __dir__))
require 'require_all'
require_all '../app'

# On-demand data-integrity check, runnable any time against the live
# current store. Built 2026-10-15 directly in response to discovering that
# a real write bug had silently reduced 704 member records to a single
# field each - the load that caused it completed cleanly, with no error
# anywhere, and the damage was only found by chance. The core write path
# now has a generic guard against this exact failure mode going forward
# (looks_like_silent_data_loss? in lib/queries.rb), but this script exists
# to catch it (or anything shaped like it) after the fact too, for
# whichever form types are in use - not member-specific.
#
# Checks:
#   1. Any current record with suspiciously few populated fields relative
#      to its own form's real field count (the "704 wiped records" shape).
#   2. Any primary_id with history snapshots but no surviving current
#      record at all (orphaned - a different, more total version of the
#      same underlying failure).
#
# Usage: ruby audit_data_integrity.rb [database_name ...]
#   No arguments: audits every dbname the ontology currently defines a
#   broad search for (member, publication, project, ...).

DATABASES = ARGV.empty? ? %w[member publication] : ARGV

SUSPICIOUS_FIELD_RATIO = 0.2 # fewer than 20% of the form's real fields populated

def audit_database(database)
  all_fields = CBGP::Dataset.fields_for(database)
  expected_count = all_fields.size
  threshold = [3, (expected_count * SUSPICIOUS_FIELD_RATIO).round].max

  graphs = execute_search(dataset_type: database, broad: true) || []
  return { suspicious: [], total: 0, expected_count: expected_count } if graphs.empty?

  raw = fetch_datasets_raw_data(graph_uris: graphs, database: database)
  suspicious = raw.filter_map do |details|
    populated = details.keys.reject { |k| k == :dataset }.size
    next unless populated <= threshold

    { graph: details[:dataset], populated: populated }
  end

  { suspicious: suspicious, total: raw.size, expected_count: expected_count }
end

def audit_orphaned_history(database)
  graphs = execute_search(dataset_type: database, broad: true) || []
  current_pids = graphs.map { |g| g.to_s.sub(%r{/\z}, '').split('/').last }.to_set

  history_graphs = HISTORY_DATABASE.query(<<~SPARQL)
    SELECT DISTINCT ?g WHERE { GRAPH ?g { ?s ?p ?o } FILTER(CONTAINS(STR(?g), '/#{database}/history/')) }
  SPARQL
  history_pids = history_graphs.filter_map do |row|
    m = row[:g].to_s.match(%r{/#{database}/history/([0-9a-f-]+)/})
    m&.captures&.first
  end.to_set

  (history_pids - current_pids).to_a
end

puts "Data integrity audit - #{Time.now.utc.iso8601}"
puts '=' * 70

DATABASES.each do |database|
  puts
  puts "--- #{database} ---"
  result = audit_database(database)
  puts "#{result[:total]} current record(s), form defines #{result[:expected_count]} field(s)"

  if result[:suspicious].empty?
    puts '  no suspiciously under-populated records found'
  else
    puts "  #{result[:suspicious].size} SUSPICIOUS record(s) (very few populated fields):"
    result[:suspicious].first(20).each { |s| puts "    #{s[:graph]} (#{s[:populated]} field(s))" }
    puts "    ... and #{result[:suspicious].size - 20} more" if result[:suspicious].size > 20
  end

  orphaned = audit_orphaned_history(database)
  if orphaned.empty?
    puts '  no orphaned history (history exists, no surviving current record)'
  else
    puts "  #{orphaned.size} ORPHANED primary_id(s) - history exists, no current record at all:"
    orphaned.first(20).each { |p| puts "    #{p}" }
  end
end

puts
puts '=' * 70
puts 'Done.'
