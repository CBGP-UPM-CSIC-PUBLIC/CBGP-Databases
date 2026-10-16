module CBGP
  class Parsers
    # Matches raw author records (as produced by datacite_parser,
    # crossref_parser, openaire_parser) against existing CBGP `member`
    # records, to find which authors of a loaded publication are CBGP
    # personnel.
    #
    # Matching is exact-token, not fuzzy string similarity: an ORCID match is
    # unambiguous; a name match requires the given name's first token to
    # agree exactly and at least one surname token to agree exactly, once
    # accents are stripped. This is deliberately looser than a full-string
    # match (see git history around 2026-08-26 for why: a live stress test
    # against 272 real CBGP personnel records found the old full-string-match
    # rule missed 239/272 - 88% - once a name was truncated the way
    # Crossref/DataCite/OpenAIRE routinely truncate them, because most CBGP
    # staff carry Spanish double surnames or compound given names).
    #
    # The looser rule is safe specifically *because* of how this matcher is
    # used: match_authors_to_personnel is only ever run against the author
    # list of a publication that is already known to include at least one
    # CBGP author (the personnel-loading admin never runs this against an
    # arbitrary/random name), so the risk being guarded against is under-
    # matching a real CBGP co-author, not a coincidental token collision
    # against a stranger. A collision (matching to the wrong CBGP member
    # among several who share a surname) is a real, non-zero residual risk
    # under this rule, accepted deliberately as the tradeoff.
    #
    # Journal/DOI-registry metadata frequently drops diacritics that the
    # canonical personnel record keeps (e.g. a paper's "Garcia" vs. the
    # authoritative "García" in the member file), so both sides are unaccented
    # before comparison - the member record's spelling is never assumed to be
    # the one that's wrong.
    #
    # @param authors [Array<Hash>] each with :name, :given, :family, :orcid
    # @param member_index [Array<Hash>, nil] a pre-loaded #load_member_index
    #   result, to reuse across many publications in one bulk load instead of
    #   re-querying all of CBGP personnel for every single publication
    # @return [Array<String>] ORCIDs of matched CBGP personnel, deduplicated
    def self.match_authors_to_personnel(authors:, member_index: nil)
      return [] if authors.to_a.empty?

      members = member_index || load_member_index

      matched = authors.filter_map do |author|
        member = find_member_by_orcid(members, author[:orcid]) ||
                 find_member_by_name(members, author[:given], author[:family])
        member && !member[:orcid].to_s.strip.empty? ? member[:orcid] : nil
      end

      matched.uniq
    end

    def self.find_member_by_orcid(members, orcid)
      # ORCID's check digit can be 'X' (uppercase, its canonical form) but at
      # least one source (OpenAIRE) returns it lowercase - upcase both sides
      # so a source-specific casing quirk can't silently break an otherwise
      # exact, unambiguous match (found 2026-08-26).
      orcid = orcid.to_s.strip.upcase
      return nil if orcid.empty?

      members.find { |m| m[:orcid].to_s.strip.upcase == orcid }
    end
    private_class_method :find_member_by_orcid

    # A hyphen (ASCII or a Unicode dash variant, e.g. the U+2010 some
    # journals use) is just a punctuation choice some sources make instead
    # of a space between two name words - not a different word boundary
    # rule. Shared by canonical_surname, given_name_matches? and
    # find_member_by_name's surname fallback so all three normalize the
    # same way.
    def self.dashes_to_spaces(value)
      value.gsub(/[‐-―-]/, ' ').gsub(/\s+/, ' ')
    end

    # True if every token on the shorter list also appears on the longer
    # one - full containment, not mere any-token overlap. Used wherever one
    # side may have been truncated to only some of the other's words (a
    # partial surname citation, a partial given name): containment still
    # accepts a genuine subset, but - unlike any-overlap - rejects two
    # different compound names that merely share one common word (e.g.
    # "Fernández-Ruiz" vs an unrelated "Fernández Soto": "ruiz" isn't in
    # the other list, so containment correctly fails where any-overlap
    # would have wrongly matched on "fernandez" alone).
    def self.pair_contained?(tokens_a, tokens_b)
      shorter, longer = tokens_a.size <= tokens_b.size ? [tokens_a, tokens_b] : [tokens_b, tokens_a]
      shorter.all? { |t| longer.include?(t) }
    end

    def self.canonical_surname(value)
      dashes_to_spaces(unaccent(value.to_s).strip.downcase)
    end

    # Journal/DOI-registry metadata routinely abbreviates the first word of a
    # compound Spanish given name to a bare initial (e.g. Crossref's
    # "M. Carmen" for a member on file as "Mª Carmen" - confirmed live
    # 2026-10-15: comparing only the first token, as this matcher used to,
    # missed that real case entirely even though the correct person and
    # their real ORCID were sitting right there in the same metadata).
    #
    # A token matches its counterpart if they're equal, or if the shorter
    # one is a single-letter initial of the longer one's first letter.
    # Requires BOTH sides to have at least 2 given-name tokens before an
    # initial-based match is allowed - a bare single initial on its own
    # (just "C.", no second word) stays rejected exactly as before: one
    # letter alone is too collision-prone to trust even under this
    # matcher's already-looser-than-usual risk tolerance (see class
    # comment).
    #
    # When either side has only one token, that token must appear
    # somewhere - not just at position 0 - among the other side's tokens
    # (still a full exact-word match, never an initial match). Confirmed
    # live (2026-10-16): our own record can carry just one of a person's
    # several given-name words (e.g. stored as "Mar"), while a source's
    # metadata gives the full compound ("M. Mar") with that shared word in
    # second position - comparing only position 0 missed this real match
    # entirely, even though it's a single-token side, which is exactly
    # where this rule is supposed to be most forgiving.
    #
    # A compound given name can be hyphenated instead of space-separated
    # (e.g. Crossref's "Jose-Luis" for a member on file as "Jose Luis") -
    # the same punctuation-styling gap canonical_surname already closes for
    # surnames (confirmed live, 2026-10-16: without this, find_member_by_name
    # never even considers the member a candidate, so a hyphenated given
    # name can block a real match further upstream too, e.g. in
    # mine_orcids_from_orcid_org.rb never trying to mine an ORCID for them).
    # Spanish connector words inside a compound given name (e.g. "Ana de
    # la Paz", "Ana del Carmen", "Ana de los Santos" - this pattern is real
    # on our own member list) carry no matching signal of their own, but
    # they do shift every later word's position - breaking the position-
    # by-position comparison below whenever a source cites the name
    # without them (e.g. "Ana Paz" for our "Ana de la Paz"). Dropped before
    # matching so position lines back up on the words that actually
    # identify someone.
    GIVEN_NAME_CONNECTORS = %w[de del la las los].freeze

    def self.tokenize_given_name(value)
      dashes_to_spaces(unaccent(value.to_s).strip.downcase).split(/\s+/)
                                                             .map { |t| t.delete('.') }
                                                             .reject { |t| GIVEN_NAME_CONNECTORS.include?(t) }
    end

    def self.given_name_matches?(source_given, member_given)
      source_tokens = tokenize_given_name(source_given)
      member_tokens = tokenize_given_name(member_given)
      return false if source_tokens.empty? || member_tokens.empty?

      return pair_contained?(source_tokens, member_tokens) if source_tokens.one? || member_tokens.one?

      source_tokens.zip(member_tokens).all? do |a, b|
        next false if a.nil? || b.nil?

        a == b || (a.length == 1 && b.start_with?(a)) || (b.length == 1 && a.start_with?(b))
      end
    end

    def self.find_member_by_name(members, given, family)
      family_tokens = dashes_to_spaces(unaccent(family.to_s).strip.downcase).split(/\s+/)
      return nil if unaccent(given.to_s).strip.empty? || family_tokens.empty?

      canonical_family = canonical_surname(family)

      members.find do |m|
        next false unless given_name_matches?(given, m[:name])

        # Whole-surname match first - confirmed live (2026-10-15) that
        # simply splitting on hyphens as an extra token separator and
        # reusing the any-token-overlap rule below creates new false
        # positives (e.g. "Fernández-Ruiz" would then also match an
        # unrelated "Fernández Soto", since both merely share the common
        # surname part "Fernández"). Comparing the full compound surname as
        # one unit fixes the real hyphen-vs-space punctuation mismatch
        # without loosening the collision risk on common single surnames.
        next true if canonical_family == canonical_surname(m[:surname])

        # Fall back to a *full-containment* check (every token on the
        # shorter side must appear on the longer side), not mere any-token
        # overlap, for the case a source only gives some of a member's
        # surname words (e.g. two of a real triple surname, or one of a
        # double surname). Both sides are hyphen-split here too - confirmed
        # live (2026-10-16): a source citing "Martin-Soto" for a member on
        # file under the full triple surname "Martín Soto Herrera" never
        # matched anything, because the un-split source token "martin-soto"
        # couldn't overlap any single member token.
        #
        # Containment (not any-overlap) is what keeps this hyphen-splitting
        # from reopening the exact collision the whole-surname check above
        # was built to avoid: "Fernández-Ruiz" split into ["fernandez",
        # "ruiz"] is NOT fully contained in an unrelated "Fernández Soto"
        # (missing "ruiz"), so it's still correctly rejected - only a
        # source surname that is a genuine subset of the member's surname
        # words is accepted, same spirit as the given-name fixes above.
        m_family_tokens = dashes_to_spaces(unaccent(m[:surname].to_s).strip.downcase).split(/\s+/)
        pair_contained?(family_tokens, m_family_tokens)
      end
    end
    private_class_method :find_member_by_name

    # Loads every member's name/surname/orcid in two queries total (one
    # broad search for the graphs, one batched fetch_datasets_raw_data call
    # for all of them) rather than one CBGP::Dataset.load_from_graph call per
    # member - that would be 2 extra SPARQL round-trips per member (~544 for
    # 272 real CBGP staff), which matters a lot here because
    # match_authors_to_personnel calls this on every single publication.
    def self.load_member_index
      graphs = execute_search(dataset_type: 'member', broad: true) || []
      return [] if graphs.empty?

      raw = fetch_datasets_raw_data(graph_uris: graphs, database: 'member')
      raw.map do |details|
        { name: details[:member_name], surname: details[:member_surnames], orcid: details[:member_orcid],
          graph: details[:dataset].to_s }
      end
    end

    # A Crossref/DataCite author entry's ORCID is self-asserted by the
    # author at submission - the same trust tier find_member_by_orcid
    # already relies on as its first, unconditional match path. When that
    # self-asserted ORCID belongs to an author who name-matches a CBGP
    # member with no ORCID on file yet, it's a real identifier for that
    # exact person, not a guess - worth writing onto their record so every
    # future publication benefits too, not just this one (confirmed live
    # 2026-10-15: Crossref had already handed us a member's real ORCID on
    # one loaded publication, unused, while this same person's name-match
    # on a different publication kept coming up empty).
    #
    # OpenAIRE-sourced authors never carry an orcid here at all (see
    # openaire_parser.rb's own comment on why that's deliberate) so they're
    # naturally excluded without any extra filtering.
    #
    # @return [Array<Hash>] {graph:, orcid:} pairs to write, deduplicated by
    #   graph - never returns a member who already has an orcid on file.
    def self.harvest_orcids_from_authors(authors:, member_index: nil)
      return [] if authors.to_a.empty?

      members = member_index || load_member_index

      authors.to_a.filter_map do |author|
        orcid = author[:orcid].to_s.strip
        next nil if orcid.empty?

        member = find_member_by_name(members, author[:given], author[:family])
        next nil unless member && member[:orcid].to_s.strip.empty? && member[:graph]

        { graph: member[:graph], orcid: orcid }
      end.uniq { |h| h[:graph] }
    end
  end
end
