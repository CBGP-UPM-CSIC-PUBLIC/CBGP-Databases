# frozen_string_literal: true

# Covers CBGP::Loaders.load_or_fetch_doi's orchestration after the redesign:
#  - resolves the DOI's registration agency first and dispatches straight to
#    datacite_parser/crossref_parser instead of blindly trying one then
#    catching+retrying (see lib/doi_registration_agency.rb);
#  - falls back to openaire_parser when the agency is unknown or the
#    preferred parser comes back empty;
#  - runs the new personnel cross-reference step and stores matched ORCIDs on
#    publication_cbgp_authors before saving.
RSpec.describe 'CBGP::Loaders.load_or_fetch_doi' do
  let(:doi) { '10.1234/example' }
  let(:pub) { CBGP::Dataset.new(type: 'publication') }

  before do
    allow(pub).to receive(:write_to_db)
    allow(CBGP::Parsers).to receive(:openaire_affiliations).with(hash_including(pub: pub, doi: doi))
    # load_or_fetch_doi now loads this itself (2026-10-16, so
    # match_authors_to_personnel and the new orcid-mining step share one
    # load instead of each loading their own) - stubbed here so these
    # mock-driven examples never hit the real network/SPARQL call.
    allow(CBGP::Parsers).to receive(:load_member_index).and_return([])
  end

  context 'when a graph for this DOI already exists' do
    it 'loads and returns the existing record without calling any parser or the agency lookup' do
      allow(CBGP::Loaders).to receive(:execute_search)
        .with(hash_including(search_params: { 'publication_doi' => doi }))
        .and_return(['graph://existing'])
      allow(CBGP::Dataset).to receive(:load_from_graph)
        .with(hash_including(graph: 'graph://existing'))
        .and_return(pub)

      expect(CBGP::Parsers).not_to receive(:resolve_doi_registration_agency)

      result = CBGP::Loaders.load_or_fetch_doi(doi: doi, database: 'publication')
      expect(result).to eq({ pub: pub, existing: true })
    end
  end

  context 'when the DOI is submitted with an https://doi.org/ resolver prefix' do
    let(:prefixed_doi) { "https://doi.org/#{doi}" }

    before do
      allow(CBGP::Loaders).to receive(:execute_search)
        .with(hash_including(search_params: { 'publication_doi' => doi }))
        .and_return([])
      allow(CBGP::Parsers).to receive(:match_authors_to_personnel).and_return([])
    end

    it 'strips the prefix before the dedupe search, the RA lookup, and the parser call' do
      expect(CBGP::Loaders).to receive(:execute_search)
        .with(hash_including(search_params: { 'publication_doi' => doi }))
        .and_return([])
      allow(CBGP::Parsers).to receive(:resolve_doi_registration_agency).with(hash_including(doi: doi)).and_return('DataCite')
      expect(CBGP::Parsers).to receive(:datacite_parser).with(hash_including(doi: doi)).and_return({ pub: pub, authors: [] })

      CBGP::Loaders.load_or_fetch_doi(doi: prefixed_doi, database: 'publication')
    end
  end

  context 'when the DOI is not yet in the database' do
    before do
      allow(CBGP::Loaders).to receive(:execute_search)
        .with(hash_including(search_params: { 'publication_doi' => doi }))
        .and_return([])
      allow(CBGP::Parsers).to receive(:match_authors_to_personnel).and_return([])
    end

    it 'dispatches DataCite-registered DOIs straight to datacite_parser' do
      allow(CBGP::Parsers).to receive(:resolve_doi_registration_agency).with(hash_including(doi: doi)).and_return('DataCite')
      expect(CBGP::Parsers).to receive(:datacite_parser).with(hash_including(doi: doi)).and_return({ pub: pub, authors: [] })
      expect(CBGP::Parsers).not_to receive(:crossref_parser)
      expect(CBGP::Parsers).not_to receive(:openaire_parser)

      CBGP::Loaders.load_or_fetch_doi(doi: doi, database: 'publication')
    end

    it 'dispatches Crossref-registered DOIs straight to crossref_parser' do
      allow(CBGP::Parsers).to receive(:resolve_doi_registration_agency).with(hash_including(doi: doi)).and_return('Crossref')
      expect(CBGP::Parsers).to receive(:crossref_parser).with(hash_including(doi: doi)).and_return({ pub: pub, authors: [] })
      expect(CBGP::Parsers).not_to receive(:datacite_parser)

      CBGP::Loaders.load_or_fetch_doi(doi: doi, database: 'publication')
    end

    it 'falls back to openaire_parser when the agency is unknown' do
      allow(CBGP::Parsers).to receive(:resolve_doi_registration_agency).with(hash_including(doi: doi)).and_return(false)
      expect(CBGP::Parsers).to receive(:openaire_parser).with(hash_including(doi: doi)).and_return({ pub: pub, authors: [] })

      CBGP::Loaders.load_or_fetch_doi(doi: doi, database: 'publication')
    end

    it 'falls back to openaire_parser when the preferred parser comes back empty' do
      allow(CBGP::Parsers).to receive(:resolve_doi_registration_agency).with(hash_including(doi: doi)).and_return('DataCite')
      allow(CBGP::Parsers).to receive(:datacite_parser).with(hash_including(doi: doi)).and_return({ pub: false, authors: [] })
      expect(CBGP::Parsers).to receive(:openaire_parser).with(hash_including(doi: doi)).and_return({ pub: pub, authors: [] })

      CBGP::Loaders.load_or_fetch_doi(doi: doi, database: 'publication')
    end

    it 'returns pub: nil without saving when every parser fails' do
      allow(CBGP::Parsers).to receive(:resolve_doi_registration_agency).with(hash_including(doi: doi)).and_return(false)
      allow(CBGP::Parsers).to receive(:openaire_parser).with(hash_including(doi: doi)).and_return({ pub: false, authors: [] })

      result = CBGP::Loaders.load_or_fetch_doi(doi: doi, database: 'publication')
      expect(result).to eq({ pub: nil, existing: false })
      expect(pub).not_to have_received(:write_to_db)
    end

    it 'sets cbgp_author_orcids from the personnel matcher and saves before returning' do
      allow(CBGP::Parsers).to receive(:resolve_doi_registration_agency).with(hash_including(doi: doi)).and_return('DataCite')
      raw_authors = [{ name: 'María García', given: 'María', family: 'García', orcid: '0000-0001-2345-6789' }]
      allow(CBGP::Parsers).to receive(:datacite_parser).with(hash_including(doi: doi)).and_return({ pub: pub, authors: raw_authors })
      allow(CBGP::Parsers).to receive(:match_authors_to_personnel)
        .with(hash_including(authors: raw_authors))
        .and_return(['0000-0001-2345-6789'])
      allow(CBGP::Parsers).to receive(:harvest_orcids_from_authors)
        .with(hash_including(authors: raw_authors))
        .and_return([])

      result = CBGP::Loaders.load_or_fetch_doi(doi: doi, database: 'publication')

      expect(pub.cbgp_author_orcids).to eq(['0000-0001-2345-6789'])
      expect(pub).to have_received(:write_to_db)
      expect(result).to eq({ pub: pub, existing: false, pending_orcid_candidates: [] })
    end

    # Covers the 2026-10-16 ORCID-mining wiring: a single-DOI load (the
    # default, mine_missing_orcids: true) searches ORCID.org inline for an
    # author who name-matches an existing member with no ORCID at all, and
    # writes it both to the member and onto this publication's own xrefs -
    # while a bulk load (mine_missing_orcids: false) must defer that same
    # candidate instead of ever calling the slow search itself (confirmed
    # live: ~2.7s per author, too slow to risk inline in a bulk request).
    context 'when an author name-matches an existing member with no ORCID at all' do
      let(:raw_authors) { [{ name: 'María García', given: 'María', family: 'García', orcid: '' }] }
      let(:member_index) { [{ name: 'María', surname: 'García', orcid: '', graph: 'graph://member/maria' }] }
      let(:member_ds) { double('member dataset', primary_id: 'maria') }

      before do
        allow(CBGP::Parsers).to receive(:resolve_doi_registration_agency).with(hash_including(doi: doi)).and_return('DataCite')
        allow(CBGP::Parsers).to receive(:datacite_parser).with(hash_including(doi: doi)).and_return({ pub: pub, authors: raw_authors })
        allow(CBGP::Parsers).to receive(:match_authors_to_personnel).and_return([])
        allow(CBGP::Parsers).to receive(:harvest_orcids_from_authors).and_return([])
        allow(CBGP::Parsers).to receive(:load_member_index).and_return(member_index)
      end

      it 'mines it inline and writes it to both the member and the publication when mine_missing_orcids is true' do
        allow(CBGP::Parsers).to receive(:mine_member_orcid)
          .with(hash_including(given: 'María', family: 'García'))
          .and_return('0000-0009-9999-9999')
        allow(CBGP::Dataset).to receive(:load_from_graph)
          .with(hash_including(database: 'member', graph: 'graph://member/maria'))
          .and_return(member_ds)
        allow(member_ds).to receive(:orcid=)
        allow(CBGP::Dataset).to receive(:write_to_db)

        result = CBGP::Loaders.load_or_fetch_doi(doi: doi, database: 'publication')

        expect(member_ds).to have_received(:orcid=).with('0000-0009-9999-9999')
        expect(CBGP::Dataset).to have_received(:write_to_db).with(dataset: member_ds, oldid: 'maria')
        expect(pub.cbgp_author_orcids).to eq(['0000-0009-9999-9999'])
        expect(result[:pending_orcid_candidates]).to eq([])
      end

      it 'defers it to pending_orcid_candidates without calling ORCID.org when mine_missing_orcids is false' do
        expect(CBGP::Parsers).not_to receive(:mine_member_orcid)

        result = CBGP::Loaders.load_or_fetch_doi(doi: doi, database: 'publication', mine_missing_orcids: false)

        expect(result[:pending_orcid_candidates]).to eq(
          [{ given: 'María', family: 'García', graph: 'graph://member/maria', doi: doi }]
        )
        expect(pub.cbgp_author_orcids).to eq([])
      end
    end
  end
end
