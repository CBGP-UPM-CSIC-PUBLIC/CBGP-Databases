# frozen_string_literal: true

# Covers match_authors_to_personnel: the new step that decides which authors
# of a loaded publication are existing CBGP `member` records, so their ORCID
# can be recorded on publication_cbgp_authors (see the ontology change adding
# that field alongside this).
#
# Matching is exact-token (an ORCID match, or a given-first-token +
# surname-any-token match after stripping accents) - never fuzzy string
# similarity. This is deliberately looser than a full-string match: see
# lib/personnel_matcher.rb's doc comment for the 2026-08-26 stress test that
# found full-string matching missed 88% of real CBGP staff once their name
# was truncated the way DOI-registry metadata routinely truncates it (double
# surnames, compound given names). The looser rule is judged safe here
# because this matcher only ever runs against a publication's author list,
# which is already known to include at least one real CBGP co-author - the
# risk being guarded against is under-matching, not a random collision.
# Journal/DOI-registry metadata is far more likely to drop diacritics than
# the canonical personnel record is, so both sides are unaccented before
# comparison rather than trusting the incoming spelling.
RSpec.describe 'CBGP::Parsers.match_authors_to_personnel' do
  # load_member_index batches all members into one fetch_datasets_raw_data
  # call (see lib/personnel_matcher.rb - avoids the N+1 of one
  # CBGP::Dataset.load_from_graph per member, which mattered a lot once
  # match_authors_to_personnel started running once per publication in a
  # bulk DOI load).
  let(:garcia_member) { { member_name: 'María', member_surnames: 'García', member_orcid: '0000-0001-2345-6789' } }
  let(:no_orcid_member) { { member_name: 'Juan', member_surnames: 'Pérez', member_orcid: '' } }
  # A realistic Spanish double-surname + compound-given-name CBGP member, to
  # cover the looser matching rule's actual purpose.
  let(:double_surname_member) { { member_name: 'Ana María', member_surnames: 'López García', member_orcid: '0000-0003-1111-2222' } }
  # Shares the first half of double_surname_member's surname only - covers
  # the 2026-10-15 hyphen fix's collision-avoidance requirement (confirmed
  # live against real Crossref data: naively treating a hyphen as an extra
  # token separator made "Fernández-Ruiz" also match an unrelated
  # "Fernández Soto", since both merely share the common surname "Fernández").
  let(:lopez_only_member) { { member_name: 'Ana', member_surnames: 'López Marcos', member_orcid: '0000-0004-3333-4444' } }
  # A genuine triple surname (common CBGP pattern) - covers the 2026-10-16
  # containment fix: a source citing only two of the three words, joined
  # with a hyphen, must still match.
  let(:triple_surname_member) { { member_name: 'Pedro', member_surnames: 'Martín Soto Herrera', member_orcid: '0000-0005-5555-6666' } }
  # A compound given name joined by a Spanish connector word, a pattern
  # that's real on several CBGP members' own records - covers the
  # 2026-10-16 connector-word fix.
  let(:connector_given_name_member) { { member_name: 'Ana de la Paz', member_surnames: 'Ortega', member_orcid: '0000-0006-7777-8888' } }

  before do
    allow(CBGP::Parsers).to receive(:execute_search)
      .with(hash_including(dataset_type: 'member', broad: true))
      .and_return(%w[graph://member/1 graph://member/2 graph://member/3 graph://member/4 graph://member/5 graph://member/6])
    allow(CBGP::Parsers).to receive(:fetch_datasets_raw_data)
      .with(hash_including(graph_uris: %w[graph://member/1 graph://member/2 graph://member/3 graph://member/4 graph://member/5 graph://member/6], database: 'member'))
      .and_return([garcia_member, no_orcid_member, double_surname_member, lopez_only_member, triple_surname_member,
                   connector_given_name_member])
  end

  it 'matches by exact ORCID when the source metadata provides one' do
    authors = [{ name: 'M García', given: 'M', family: 'García', orcid: '0000-0001-2345-6789' }]

    expect(CBGP::Parsers.match_authors_to_personnel(authors: authors)).to eq(['0000-0001-2345-6789'])
  end

  it 'falls back to an exact accent-insensitive given+family match when there is no ORCID' do
    authors = [{ name: 'Maria Garcia', given: 'Maria', family: 'Garcia', orcid: '' }]

    expect(CBGP::Parsers.match_authors_to_personnel(authors: authors)).to eq(['0000-0001-2345-6789'])
  end

  it 'does not match on surname alone (avoids a false positive across two different people)' do
    authors = [{ name: 'Pedro García', given: 'Pedro', family: 'García', orcid: '' }]

    expect(CBGP::Parsers.match_authors_to_personnel(authors: authors)).to eq([])
  end

  it 'skips an outside co-author with no ORCID and no matching member name' do
    authors = [{ name: 'Jane Outsider', given: 'Jane', family: 'Outsider', orcid: '' }]

    expect(CBGP::Parsers.match_authors_to_personnel(authors: authors)).to eq([])
  end

  it 'skips a name match against a member who has no ORCID on file' do
    authors = [{ name: 'Juan Pérez', given: 'Juan', family: 'Perez', orcid: '' }]

    expect(CBGP::Parsers.match_authors_to_personnel(authors: authors)).to eq([])
  end

  it 'deduplicates when the same member is matched more than once' do
    authors = [
      { name: 'M García', given: 'M', family: 'García', orcid: '0000-0001-2345-6789' },
      { name: 'Maria Garcia', given: 'Maria', family: 'Garcia', orcid: '' }
    ]

    expect(CBGP::Parsers.match_authors_to_personnel(authors: authors)).to eq(['0000-0001-2345-6789'])
  end

  it 'matches a truncated second surname against a double-surname member (the looser rule)' do
    authors = [{ name: 'Ana García', given: 'Ana', family: 'García', orcid: '' }]

    expect(CBGP::Parsers.match_authors_to_personnel(authors: authors)).to eq(['0000-0003-1111-2222'])
  end

  it 'matches a compound given name via its first token only' do
    authors = [{ name: 'Ana López García', given: 'Ana María', family: 'López', orcid: '' }]

    expect(CBGP::Parsers.match_authors_to_personnel(authors: authors)).to eq(['0000-0003-1111-2222'])
  end

  it 'still requires the given name to agree, even with the looser surname rule' do
    authors = [{ name: 'Pedro García', given: 'Pedro', family: 'García', orcid: '' }]

    expect(CBGP::Parsers.match_authors_to_personnel(authors: authors)).to eq([])
  end

  it 'matches a hyphenated compound surname against the same surname written with a space' do
    authors = [{ name: 'Ana López-García', given: 'Ana', family: 'López-García', orcid: '' }]

    expect(CBGP::Parsers.match_authors_to_personnel(authors: authors)).to eq(['0000-0003-1111-2222'])
  end

  it 'matches a compound given name whose first word is abbreviated to an initial, confirmed by the second word' do
    # Mirrors the real case this was built for (2026-10-15): Crossref's
    # "M. Carmen Ruiz" for a member on file as "Mª Carmen
    # Ruiz Soto" - the second given-name word is what makes this
    # safe to accept despite the first being a bare initial.
    authors = [{ name: 'A. María López García', given: 'A. María', family: 'López', orcid: '' }]

    expect(CBGP::Parsers.match_authors_to_personnel(authors: authors)).to eq(['0000-0003-1111-2222'])
  end

  it 'does not match when the given name is reduced to a single bare initial with no second word' do
    authors = [{ name: 'A. López García', given: 'A.', family: 'López García', orcid: '' }]

    expect(CBGP::Parsers.match_authors_to_personnel(authors: authors)).to eq([])
  end

  it 'matches a one-word stored given name against a compound source given name sharing it, at any position' do
    # Mirrors a real case (2026-10-16): a source gave a two-word given name
    # ("M. Mar") for a member whose own record only carries one of those
    # words ("Mar"). Comparing only the source's first token against the
    # member's single token ("m" vs "mar") missed this entirely - the
    # shared word is in the source's second position, not its first.
    authors = [{ name: 'M. Ana López', given: 'M. Ana', family: 'López', orcid: '' }]

    expect(CBGP::Parsers.match_authors_to_personnel(authors: authors)).to eq(['0000-0004-3333-4444'])
  end

  it 'does not match a one-word stored given name against a compound source given name that never contains it' do
    authors = [{ name: 'M. Elena López', given: 'M. Elena', family: 'López', orcid: '' }]

    expect(CBGP::Parsers.match_authors_to_personnel(authors: authors)).to eq([])
  end

  it 'matches a hyphenated compound given name against the same given name written with a space' do
    # Mirrors a real case (2026-10-16): Crossref's "Ana-María" for a member
    # on file as "Ana María" - the same punctuation-styling gap already
    # fixed for surnames, now closed for given names too.
    authors = [{ name: 'Ana-María López García', given: 'Ana-María', family: 'López', orcid: '' }]

    expect(CBGP::Parsers.match_authors_to_personnel(authors: authors)).to eq(['0000-0003-1111-2222'])
  end

  it 'matches a connector-free given name against a member whose record keeps the Spanish connector word' do
    # Mirrors a real case (2026-10-16): Crossref cited a member by a
    # shortened given name with no connector word, while our own record -
    # like several real CBGP members - keeps "de la" in the stored name.
    # Without dropping connector words first, position-by-position
    # comparison misaligns on every word after the connector.
    authors = [{ name: 'Ana Paz Ortega', given: 'Ana Paz', family: 'Ortega', orcid: '' }]

    expect(CBGP::Parsers.match_authors_to_personnel(authors: authors)).to eq(['0000-0006-7777-8888'])
  end

  it 'matches a hyphenated two-word surname citation against a member whose real surname has a third word' do
    # Mirrors a real case (2026-10-16): a source citing "Martin-Soto" for a
    # member on file under the full triple surname "Martín Soto Herrera" -
    # the source only cites two of the three words, joined with a hyphen.
    # The un-split token "martin-soto" couldn't overlap any single member
    # token before this fix.
    authors = [{ name: 'Pedro Martin-Soto', given: 'Pedro', family: 'Martin-Soto', orcid: '' }]

    expect(CBGP::Parsers.match_authors_to_personnel(authors: authors)).to eq(['0000-0005-5555-6666'])
  end

  it 'does not let a hyphenated compound surname collide with an unrelated member sharing only half of it' do
    # "López-Pérez" shares "López" with both double_surname_member (López
    # García) and lopez_only_member (López Marcos) but matches neither
    # surname fully - must resolve to no match, not a guess at either one.
    authors = [{ name: 'Ana López-Pérez', given: 'Ana', family: 'López-Pérez', orcid: '' }]

    expect(CBGP::Parsers.match_authors_to_personnel(authors: authors)).to eq([])
  end

  it 'returns an empty array for an empty author list without querying members' do
    expect(CBGP::Parsers).not_to receive(:execute_search)
    expect(CBGP::Parsers.match_authors_to_personnel(authors: [])).to eq([])
  end
end

# Covers harvest_orcids_from_authors: when a source's own metadata carries a
# self-asserted ORCID for an author who name-matches a CBGP member with none
# on file, that ORCID gets handed back for the caller (lib/loaders.rb) to
# write onto the member's record. Built 2026-10-15 after confirming live
# that Crossref had already supplied a real member's ORCID on one loaded
# publication while that same person's name match on a different
# publication kept coming up empty, for lack of anywhere to have stored it.
RSpec.describe 'CBGP::Parsers.harvest_orcids_from_authors' do
  let(:no_orcid_member) do
    { member_name: 'Mª Carmen', member_surnames: 'Ruiz Soto', member_orcid: '',
      dataset: 'graph://member/ruiz' }
  end
  let(:has_orcid_member) do
    { member_name: 'Juan', member_surnames: 'Pérez', member_orcid: '0000-0009-8888-7777',
      dataset: 'graph://member/perez' }
  end

  before do
    allow(CBGP::Parsers).to receive(:execute_search)
      .with(hash_including(dataset_type: 'member', broad: true))
      .and_return(%w[graph://member/ruiz graph://member/perez])
    allow(CBGP::Parsers).to receive(:fetch_datasets_raw_data)
      .with(hash_including(graph_uris: %w[graph://member/ruiz graph://member/perez], database: 'member'))
      .and_return([no_orcid_member, has_orcid_member])
  end

  it 'harvests a self-asserted ORCID for a name-matched member who has none on file' do
    authors = [{ name: 'M. Carmen Ruiz', given: 'M. Carmen', family: 'Ruiz',
                 orcid: '0000-0002-4444-5555' }]

    expect(CBGP::Parsers.harvest_orcids_from_authors(authors: authors))
      .to eq([{ graph: 'graph://member/ruiz', orcid: '0000-0002-4444-5555' }])
  end

  it 'does not harvest when the matched member already has an ORCID on file' do
    authors = [{ name: 'Juan Pérez', given: 'Juan', family: 'Pérez', orcid: '0000-0001-1111-1111' }]

    expect(CBGP::Parsers.harvest_orcids_from_authors(authors: authors)).to eq([])
  end

  it 'does not harvest when the source gave no ORCID for that author' do
    authors = [{ name: 'M. Carmen Ruiz', given: 'M. Carmen', family: 'Ruiz', orcid: '' }]

    expect(CBGP::Parsers.harvest_orcids_from_authors(authors: authors)).to eq([])
  end

  it 'does not harvest when the author does not name-match any member' do
    authors = [{ name: 'Jane Outsider', given: 'Jane', family: 'Outsider', orcid: '0000-0002-2222-2222' }]

    expect(CBGP::Parsers.harvest_orcids_from_authors(authors: authors)).to eq([])
  end

  it 'returns an empty array for an empty author list without querying members' do
    expect(CBGP::Parsers).not_to receive(:execute_search)
    expect(CBGP::Parsers.harvest_orcids_from_authors(authors: [])).to eq([])
  end
end
