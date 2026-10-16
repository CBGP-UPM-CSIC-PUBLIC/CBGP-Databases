require 'dotenv'
Dotenv.load(File.expand_path('../.env', __dir__))
require 'require_all'
require_all '../app'

abort 'provide the zero-xref DOI list file as ARGV[0]' unless ARGV[0]
dois = File.readlines(ARGV[0], chomp: true).map(&:strip).reject(&:empty?)

OUT = '/home/osboxes/Desktop/CBGP Databases/For Curation/publications_with_no_author_match.csv'.freeze

# The saved publication_authors field only ever stored flattened "Given
# Family" strings (the ontology field has nowhere to keep a per-author
# ORCID) - re-fetching from the source here, same as the other curation
# scripts, is the only way to show Anna which authors already carry a
# self-asserted ORCID in their own paper's metadata, to help her see at a
# glance who's independently verifiable versus who needs a real lookup.
def fetch_authors(doi)
  agency = CBGP::Parsers.resolve_doi_registration_agency(doi: doi)
  result = case agency
           when 'DataCite' then CBGP::Parsers.datacite_parser(doi: doi)
           when 'Crossref' then CBGP::Parsers.crossref_parser(doi: doi)
           else { pub: false, authors: [] }
           end
  result = CBGP::Parsers.openaire_parser(doi: doi) unless result[:pub]
  result[:authors] || []
end

CSV.open(OUT, 'w') do |csv|
  csv << %w[doi orcids title authors]
  dois.each do |doi|
    graphs = execute_search(search_params: { 'publication_doi' => doi }, dataset_type: 'publication')
    graph = graphs&.first
    next unless graph

    pub = CBGP::Dataset.load_from_graph(graph: graph, database: 'publication',
                                         pre_fetched_primary_id: graph.split('/').last)

    authors = fetch_authors(doi)
    # Positionally parallel to the authors column (blank where that author
    # has no ORCID in the source metadata), not just a dumped list, so
    # Anna can line an ORCID up against the name it belongs to.
    orcids = authors.map { |a| a[:orcid].to_s.strip }.join('; ')

    csv << [doi, orcids, pub.title, Array(pub.authors).join('; ')]
  end
end

puts "Wrote #{dois.size} rows to #{OUT}"
