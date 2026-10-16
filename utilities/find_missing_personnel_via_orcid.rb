require 'dotenv'
Dotenv.load(File.expand_path('../.env', __dir__))
require 'require_all'
require_all '../app'

# Checks every author on every publication passed in, except any author who
# DOES name-match an existing member, against ORCID.org's public registry -
# the same search as lib/orcid_mining.rb (CBGP::Parsers.orcid_search) - but
# here the point isn't filling in a missing ORCID for an already-known
# member (that's CBGP::Parsers.mine_member_orcid's job, used by this
# script's sibling mine_orcids_from_orcid_org.rb), it's finding evidence
# that an author is a REAL CBGP person entirely absent from all 4 source
# files (historico/personal_merged, activos, id_CBGP.csv, CBGP ORCID
# Codes.xlsx). The name-match exclusion matters: a publication can have
# zero written xrefs simply because its real matches are to existing
# orcid-less members, not because its authors are unknown to us - without
# excluding those first, this script would wrongly tell Anna to create a
# duplicate record for someone who already exists (confirmed live,
# 2026-10-16).
#
# This script's acceptance policy is deliberately STRICTER than mine_
# orcids_from_orcid_org.rb's: only an EXPLICIT CBGP mention counts here,
# never a broad-umbrella-only match (CSIC/UPM/INIA) - see the explanation
# further down, by the acceptance logic itself, for why.
#
# IMPORTANT - feed this ALL publication DOIs in the batch being worked on,
# never a "zero-xref publications only" pre-filtered list. Confirmed live
# (2026-10-16): a real missing person (actually two) went undetected because
# they co-authored a paper alongside a DIFFERENT author who DID resolve -
# giving that publication a non-zero xref count and silently dropping it,
# and every other author on it, out of any "zero xref" filter from then on.
# This script's own per-author exclusion check (above) is what actually
# does the filtering correctly; a publication-level xref-count pre-filter
# is redundant at best and actively hides genuine findings at worst.
# Built 2026-10-15 after the user spotted exactly this case by hand: Jane
# Doe, author on 3 loaded publications, whose own ORCID record lists "Centro
# de Biotecnología y Genómica de Plantas" (our institute's correct full
# name) as an affiliation, yet who has no member record at all to match
# against. Per the user's explicit decision: this script only REPORTS such
# people for Anna/Sara to add properly with real institute data - it never
# creates a member record from external ORCID data alone.
OUT = '/home/osboxes/Desktop/CBGP Databases/For Curation/missing_personnel_found_via_orcid.csv'.freeze
AMBIGUOUS_OUT = '/home/osboxes/Desktop/CBGP Databases/For Curation/missing_personnel_ambiguous.csv'.freeze

# Calls lib/personnel_matcher.rb's actual (private) find_member_by_name via
# send, rather than keeping a local duplicate - same reasoning as the
# identical wrapper in mine_orcids_from_orcid_org.rb: a duplicate can drift
# out of sync with real fixes made to the production matcher.
def find_member_by_name(members, given, family)
  CBGP::Parsers.send(:find_member_by_name, members, given, family)
end

unless ARGV[0]
  abort 'provide a file of ALL publication DOIs in this batch as ARGV[0] - ' \
        'not a zero-xref-only list, see the file header'
end
dois = File.readlines(ARGV[0], chomp: true).map(&:strip).reject(&:empty?)

# A "zero-xref" publication means no author ended up with a WRITTEN orcid -
# which also happens when every real match is to an existing member who
# simply has no orcid on file yet (see mine_orcids_from_orcid_org.rb). That
# case must never land here: confirmed live (2026-10-16) that without this
# check, an author who already has a real CBGP member record (just orcid-
# less) was reported as "no member record at all", which would have told
# Anna to create a brand-new, duplicate record for someone who already
# exists. Only an author find_member_by_name can't place at all is a
# genuine missing-personnel candidate.
members = CBGP::Parsers.load_member_index

# Dedup by normalized name first - the same real/absent person often
# co-authors more than one of these papers (confirmed: Jane Doe on 2 of
# them already), no point searching ORCID.org twice for the same name.
candidates = {} # normalized name key => { given:, family:, dois: [] }
dois.each do |doi|
  agency = CBGP::Parsers.resolve_doi_registration_agency(doi: doi)
  result = case agency
           when 'DataCite' then CBGP::Parsers.datacite_parser(doi: doi)
           when 'Crossref' then CBGP::Parsers.crossref_parser(doi: doi)
           else { pub: false, authors: [] }
           end
  result = CBGP::Parsers.openaire_parser(doi: doi) unless result[:pub]

  (result[:authors] || []).each do |author|
    next if author[:given].to_s.strip.empty? || author[:family].to_s.strip.empty?
    next if find_member_by_name(members, author[:given], author[:family])

    key = "#{unaccent(author[:given]).downcase.strip} #{unaccent(author[:family]).downcase.strip}"
    candidates[key] ||= { given: author[:given], family: author[:family], dois: [] }
    candidates[key][:dois] << doi
  end
end

puts "#{candidates.size} distinct unmatched author names across #{dois.size} publications."

found = []
ambiguous = []
candidates.each_value do |info|
  results = CBGP::Parsers.orcid_search(given: info[:given], family: info[:family])
  name_matched = results.select { |c| CBGP::Parsers.orcid_candidate_name_matches?(c, info[:given], info[:family]) }
  explicit = name_matched.select { |c| CBGP::Parsers.explicit_cbgp_match?(c) }
  broad = name_matched.select { |c| CBGP::Parsers.broad_umbrella_match?(c) }

  # Only an EXPLICIT CBGP mention is confident enough to assert "this is a
  # real CBGP person missing from our data" - a claim that would tell Anna
  # to create a brand-new member record. CSIC, UPM and INIA are each large
  # umbrella organizations CBGP is merely one small part of, and this
  # script has no prior at all that the person is CBGP-affiliated (unlike
  # mine_orcids_from_orcid_org.rb, which only ever runs against someone
  # ALREADY known to be a real member from our own database, so a broad-
  # umbrella match there just helps find THEIR orcid, not establish their
  # existence). Confirmed live (2026-10-16): on a 100-DOI batch, the broad
  # tier alone flagged 47 people as "likely real, missing" - spot-checking
  # found them to be real, prominent scientists at OTHER CSIC/UPM-adjacent
  # institutes entirely unrelated to CBGP (e.g. CNB-CSIC, CRAG), not
  # missing CBGP members at all. A broad-only match is demoted to the same
  # "can't confidently pick one" curation file as a genuine name collision,
  # not asserted as a finding.
  if explicit.size == 1
    cand = explicit.first
    puts "LIKELY REAL CBGP PERSON, MISSING FROM OUR DATA: #{info[:given]} #{info[:family]} -> " \
         "#{cand['orcid-id']} (#{cand['institution-name']}) on #{info[:dois].join(', ')}"
    found << { given: info[:given], family: info[:family], orcid: cand['orcid-id'],
               confidence: 'STRONG (explicit CBGP mention)',
               institutions: Array(cand['institution-name']).join('; '), dois: info[:dois].join('; ') }
  elsif explicit.size > 1 || broad.any?
    # Logged, not dropped - a human can resolve a same-name collision or
    # weigh a weak umbrella-only signal a script correctly refuses to
    # guess at.
    all = (explicit + broad).uniq { |c| c['orcid-id'] }
    puts "WEAK/AMBIGUOUS (#{all.size} candidate(s), no confident single pick): " \
         "#{info[:given]} #{info[:family]} on #{info[:dois].join(', ')}"
    ambiguous << { given: info[:given], family: info[:family],
                   candidate_orcids: all.map { |c| c['orcid-id'] }.join('; '), dois: info[:dois].join('; ') }
  end
  sleep 0.3
end

CSV.open(OUT, 'w') do |csv|
  csv << %w[given family orcid confidence institutions_on_orcid_profile papers]
  found.sort_by { |f| f[:confidence] }.each do |f|
    csv << [f[:given], f[:family], f[:orcid], f[:confidence], f[:institutions], f[:dois]]
  end
end

CSV.open(AMBIGUOUS_OUT, 'w') do |csv|
  csv << %w[given family candidate_orcids papers]
  ambiguous.each { |a| csv << [a[:given], a[:family], a[:candidate_orcids], a[:dois]] }
end

puts
puts "Done. #{found.size} likely-real CBGP person(s) found with no member record at all - see #{OUT}"
puts "#{ambiguous.size} ambiguous same-name case(s) logged, not guessed at - see #{AMBIGUOUS_OUT}"
