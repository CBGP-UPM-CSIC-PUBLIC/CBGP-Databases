require 'dotenv'
Dotenv.load(File.expand_path('../.env', __dir__))
require 'require_all'
require_all '../app'

# Recovery for the 704-record incident (2026-10-15, see
# project_doi_xref_gap_closing / this session's memory): mark_departed_
# historical.rb read each record via a graph URI built from the wrong RDF
# namespace (subject URI instead of the real named graph), silently got an
# empty read back, and wrote that empty object over the real one - keeping
# only the one field (member_status) it explicitly set.
#
# Each of these 704 people's *last correct* state is still intact as their
# most recent history snapshot (the wipe pushed it there before replacing
# current) - this restores exactly that snapshot as the new current record,
# reusing the same primary_id so the history chain stays correctly linked,
# with member_status explicitly re-set to 'historical' (independently known
# correct for all 704, since none of them are in usuarios_activos).
abort 'provide the wiped-primary-ids list file as ARGV[0]' unless ARGV[0]
wiped_pids = File.readlines(ARGV[0], chomp: true).map(&:strip).reject(&:empty?)

member_fields = CBGP::Dataset.fields_for('member')

def method_for_questionclass(questionclass, member_fields)
  member_fields.find { |f| f[:questionclass] == questionclass }&.dig(:method)
end

recovered = 0
failed = []

wiped_pids.each do |pid|
  snapshots = HISTORY_DATABASE.query(<<~SPARQL)
    PREFIX prov: <http://www.w3.org/ns/prov#>
    SELECT ?g ?t WHERE {
      GRAPH ?g { ?g prov:generatedAtTime ?t }
      FILTER(CONTAINS(STR(?g), '/member/history/#{pid}/'))
    } ORDER BY DESC(?t) LIMIT 1
  SPARQL

  if snapshots.empty?
    warn "  NO HISTORY SNAPSHOT FOUND for #{pid} - skipping"
    failed << pid
    next
  end

  latest_graph = snapshots.first[:g].to_s

  field_rows = HISTORY_DATABASE.query(<<~SPARQL)
    PREFIX sio: <http://semanticscience.org/resource/>
    SELECT ?questionclass ?val WHERE {
      GRAPH <#{latest_graph}> {
        ?s sio:SIO_000008 ?attr .
        ?attr a ?qc .
        ?attr sio:SIO_000300 ?val .
        BIND(STRAFTER(STR(?qc), '#') AS ?questionclass)
      }
    }
  SPARQL

  if field_rows.empty?
    warn "  SNAPSHOT #{latest_graph} HAS NO FIELD DATA EITHER - skipping #{pid}"
    failed << pid
    next
  end

  ds = CBGP::Dataset.new(type: 'member')
  ds.primary_id = pid

  field_rows.each do |row|
    questionclass = row[:questionclass].to_s
    value = row[:val].to_s
    next if questionclass == 'member_status' # restored explicitly below, not from the snapshot

    method_name = method_for_questionclass(questionclass, member_fields)
    unless method_name
      warn "  no member field matches questionclass '#{questionclass}' - skipping that one value for #{pid}"
      next
    end
    ds.public_send("#{method_name}=", value)
  end

  ds.status = 'historical'

  CBGP::Dataset.write_to_db(dataset: ds, oldid: pid)
  recovered += 1
end

puts
puts "Done. #{recovered} record(s) recovered from their latest history snapshot."
puts "#{failed.size} could not be recovered (no usable history found): #{failed.join(', ')}" if failed.any?
