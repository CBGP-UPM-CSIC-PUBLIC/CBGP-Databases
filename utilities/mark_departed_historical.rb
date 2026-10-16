require 'dotenv'
Dotenv.load(File.expand_path('../.env', __dir__))
require 'require_all'
require_all '../app'

# Sanity-check fix (2026-10-15): the 792 current members not present in
# usuarios_activos were left with member_status blank by the original
# change-log load (personal_CBGP_FINAL_MERGED.csv's own status column was
# essentially empty). Absence from activos *is* the ground truth for "not
# currently active", per the user, so these records get member_status =
# historical here - except the 88 whose own change-log data conflicts
# (status already said active, or no end_date was ever recorded), which are
# curated instead of guessed at (see activos_status_anomalies_curation.csv).
#
# load_from_graph + rewrite (not a raw field patch) so every other field on
# the record is preserved exactly - a write is a full snapshot, not a diff.

abort 'provide the safe_to_historical.csv path as ARGV[0]' unless ARGV[0]
rows = CSV.read(ARGV[0], headers: true)

count = 0
rows.each do |row|
  graph = row['graph']
  # retrieve_dataset_id_from_graph_query's own identifier-node lookup
  # (sio:SIO_000671/SIO_000115) comes back empty for member records - this
  # app derives primary_id from the graph URI's own last path segment
  # everywhere else (see fetch_datasets_raw_data), so supply it directly
  # rather than letting load_from_graph fall back to that unused query.
  ds = CBGP::Dataset.load_from_graph(graph: graph, database: 'member', pre_fetched_primary_id: graph.split('/').last)
  ds.status = 'historical'
  CBGP::Dataset.write_to_db(dataset: ds, oldid: ds.primary_id)
  count += 1
end

puts "Done. #{count} records updated to member_status = historical."
