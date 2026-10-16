require 'dotenv'
Dotenv.load(File.expand_path('../.env', __dir__))
require 'require_all'
require_all '../app'

abort 'provide the zero-xref DOI list file as ARGV[0]' unless ARGV[0]
dois = File.readlines(ARGV[0], chomp: true).map(&:strip).reject(&:empty?)

dois.each do |doi|
  agency = CBGP::Parsers.resolve_doi_registration_agency(doi: doi)
  source = agency
  result = case agency
           when 'DataCite' then CBGP::Parsers.datacite_parser(doi: doi)
           when 'Crossref' then CBGP::Parsers.crossref_parser(doi: doi)
           else { pub: false, authors: [] }
           end
  unless result[:pub]
    result = CBGP::Parsers.openaire_parser(doi: doi)
    source = 'OpenAIRE'
  end

  puts "DOI #{doi} (source=#{source})"
  (result[:authors] || []).each do |a|
    puts "    given=#{a[:given].inspect} family=#{a[:family].inspect} orcid=#{a[:orcid].inspect}"
  end
  puts
end
