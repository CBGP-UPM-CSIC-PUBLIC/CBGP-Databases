# frozen_string_literal: true

require 'net/http'
require 'json'

module CBGP
  class Parsers
    # Searches ORCID.org's public registry for a CBGP-affiliated identity
    # match, for an author who already name-matches an EXISTING CBGP member
    # with no ORCID on file. Institute-specific (hardcoded Spanish institute
    # name variants below, not derivable from the live ontology, which only
    # has the bare codes UPM/CSIC/INIA/CBGP as labels) - deliberately kept
    # out of the generic engine, same reasoning as lib/personnel_matcher.rb's
    # own institute-adjacent matching.
    #
    # Originally a standalone utility script (utilities/mine_orcids_from_
    # orcid_org.rb, 2026-10-15), promoted into lib/ on 2026-10-16 so the
    # live DOI-load path (lib/loaders.rb) and the batch utility scripts
    # share one implementation instead of two copies that can drift out of
    # sync - confirmed live that exact drift already happened once today
    # (a duplicate in utilities/find_missing_personnel_via_orcid.rb missed
    # the hyphen fix made here).
    #
    # Per the user's explicit trust criterion: a name hit alone against
    # ORCID's public registry proves nothing (common names collide -
    # confirmed live: a search for "Elena Torres" returns an unrelated
    # "Torres-Molina" first). Only auto-assign when BOTH (a) the name
    # matches and (b) that same ORCID candidate's own public employment
    # history includes our institute. That's an independent, authoritative
    # signal - not a guess - so it's allowed to write directly to the
    # member record, unlike a bare name match.
    #
    # CSIC, UPM and INIA are each large umbrella organizations CBGP is
    # merely one small part of (CSIC alone sits over ~120 separate
    # institutes) - confirmed live (2026-10-15) that pooling a bare "csic"/
    # "upm" match together with an explicit CBGP mention let an unrelated
    # same-name person at a totally different CSIC institute silently
    # cancel out a real match via a combined ambiguity check. Kept as two
    # separate tiers so an explicit mention always wins outright, never
    # diluted by an unrelated umbrella-only candidate. The broad-umbrella
    # tier is only safe to auto-accept here because the person's CBGP
    # membership is ALREADY established (an existing member record found
    # this author by name) - it is NOT safe evidence that a random,
    # previously-unknown author IS a CBGP person at all. Confirmed live
    # (2026-10-16): using the broad tier to assert "this unknown author is
    # a real CBGP person missing from our data" (utilities/find_missing_
    # personnel_via_orcid.rb's old behavior) produced ~47 false positives
    # on a 100-DOI batch - real, prominent scientists at OTHER CSIC/UPM-
    # adjacent institutes who simply co-authored with a CBGP member. That
    # caller now requires an explicit match; this module stays permissive
    # for the narrower, already-vetted "find an existing member's orcid"
    # case.
    EXPLICIT_CBGP_FRAGMENTS = ['cbgp', 'centro de biotecnologia y genomica de plantas',
                               'biotechnology and plant genomics'].freeze
    BROAD_UMBRELLA_FRAGMENTS = [
      'upm', 'politecnica de madrid', 'technical university of madrid',
      'csic', 'consejo superior de investigaciones cientificas', 'spanish national research council',
      'inia', 'instituto nacional de investigacion', 'national institute for agricultural'
    ].freeze

    # Plain substring matching on a short acronym fragment ('inia', 'upm',
    # 'csic') is a real, confirmed bug, not a theoretical one: "University
    # of Virginia" contains "inia" as a literal substring ("virg-INIA"),
    # which wrongly flagged several completely unrelated Virginia-based
    # institutions as an INIA affiliation once a wider general-search
    # candidate pool gave this latent flaw far more chances to fire than a
    # narrower pool ever did (confirmed live, 2026-10-16). Word-boundary
    # matching (the fragment can't be embedded inside a longer run of
    # letters on either side) fixes this without weakening genuine
    # matches, since every real institution phrase here is bounded by
    # spaces/punctuation in practice.
    def self.fragment_present?(text, fragment)
      text.match?(/(?<![\p{L}])#{Regexp.escape(fragment)}(?![\p{L}])/)
    end

    def self.orcid_search_once(given:, family:)
      q = "given-names:#{ERB::Util.url_encode(given)}+AND+family-name:#{ERB::Util.url_encode(family)}"
      uri = URI("https://pub.orcid.org/v3.0/expanded-search/?q=#{q}")
      res = Net::HTTP.get_response(uri, { 'Accept' => 'application/json' })
      return [] unless res.is_a?(Net::HTTPSuccess)

      JSON.parse(res.body)['expanded-result'] || []
    rescue StandardError => e
      warn "  ORCID search failed for #{given} #{family}: #{e.message}"
      []
    end

    # ORCID's general/unstructured search (no given-names:/family-name:
    # field restriction) ranks by relevance rather than requiring a tight
    # field match - confirmed live (2026-10-16) that it finds real profiles
    # the field-restricted query above misses entirely, including as the
    # very top hit for a bare-initial given name ("P. Martin-Soto" ->
    # the correct "Pedro Martin Soto Herrera" at position 1 of 1000,
    # vs 0 results via the field query). Likely closer to what ORCID's own
    # website search box does. Kept as a separate, additional attempt
    # rather than a replacement, since the field query is cheaper and
    # still useful when it works.
    def self.orcid_general_search(full_name)
      uri = URI("https://pub.orcid.org/v3.0/expanded-search/?q=#{ERB::Util.url_encode(full_name)}")
      res = Net::HTTP.get_response(uri, { 'Accept' => 'application/json' })
      return [] unless res.is_a?(Net::HTTPSuccess)

      JSON.parse(res.body)['expanded-result'] || []
    rescue StandardError => e
      warn "  ORCID general search failed for #{full_name}: #{e.message}"
      []
    end

    # Tries both the name exactly as given (accents intact - e.g. "Díaz")
    # and the fully unaccented form ("Diaz"), the given name's first word
    # alone when it has more than one word, and both accented/unaccented
    # general searches - merged and deduplicated by ORCID iD. Confirmed
    # live (2026-10-16) each of these widens the net to real matches the
    # others miss (e.g. "José Domingo" the full compound found nothing,
    # "Jose" alone found the real profile as the first hit). Costs ~2.7
    # seconds per author end to end (6 HTTP round-trips with politeness
    # sleeps) - see the caller for why this must never run synchronously
    # in a bulk/multi-author context.
    def self.orcid_search(given:, family:)
      results = orcid_search_once(given: given, family: family)
      sleep 0.2
      results += orcid_search_once(given: unaccent(given), family: unaccent(family))

      first_word = unaccent(given).strip.split(/\s+/).first.to_s
      if first_word.downcase != unaccent(given).strip.downcase && !first_word.empty?
        sleep 0.2
        results += orcid_search_once(given: first_word, family: unaccent(family))
      end

      sleep 0.2
      results += orcid_general_search("#{given} #{family}")
      sleep 0.2
      results += orcid_general_search("#{unaccent(given)} #{unaccent(family)}")

      results.uniq { |c| c['orcid-id'] }
    end

    def self.explicit_cbgp_match?(candidate)
      names = Array(candidate['institution-name']).map { |n| unaccent(n.to_s).downcase }
      names.any? { |n| EXPLICIT_CBGP_FRAGMENTS.any? { |frag| fragment_present?(n, frag) } }
    end

    def self.broad_umbrella_match?(candidate)
      names = Array(candidate['institution-name']).map { |n| unaccent(n.to_s).downcase }
      names.any? { |n| BROAD_UMBRELLA_FRAGMENTS.any? { |frag| fragment_present?(n, frag) } }
    end

    # Family-name tokens are hyphen-split via dashes_to_spaces and compared
    # with containment (not any-overlap) - same collision-safety reasoning
    # as find_member_by_name's own hyphen fix. A bare single-letter given-
    # name initial is accepted here, unlike given_name_matches?'s stricter
    # rule - deliberately, because this search has an independent
    # corroborating signal the bare DOI-author matcher doesn't: the
    # institute-affiliation double-match above. Confirmed live (2026-10-16)
    # that rejecting the initial outright meant a real, already-known
    # member stayed permanently invisible on one citation, while general
    # search found his exact profile as the #1 hit; the explicit/
    # unambiguous-broad acceptance gate still protects against a common
    # initial colliding with an unrelated person of the same rare surname.
    def self.orcid_candidate_name_matches?(candidate, given, family)
      cand_given_first = unaccent(candidate['given-names'].to_s).strip.downcase.split(/\s+/).first.to_s
      given_first = unaccent(given).strip.downcase.split(/\s+/).first.to_s
      initial_match = given_first.length == 1 && cand_given_first.start_with?(given_first)
      return false unless cand_given_first == given_first || initial_match

      cand_family = dashes_to_spaces(unaccent(candidate['family-names'].to_s).strip.downcase)
      member_family = dashes_to_spaces(unaccent(family).strip.downcase)
      pair_contained?(cand_family.split(/\s+/), member_family.split(/\s+/))
    end

    # Public entry point: for an author who already name-matches an
    # EXISTING CBGP member with no ORCID on file, search ORCID.org and
    # return the confirmed orcid id if found (explicit CBGP mention, or an
    # unambiguous broad-umbrella match when nothing explicit turned up),
    # else nil. No side effects - the caller decides whether/how to write
    # it. NOT safe to use for "is this unknown author a CBGP person at
    # all" - see the broad-umbrella-tier caveat in this file's header.
    def self.mine_member_orcid(given:, family:)
      results = orcid_search(given: given, family: family)
      name_matched = results.select { |c| orcid_candidate_name_matches?(c, given, family) }
      explicit = name_matched.select { |c| explicit_cbgp_match?(c) }
      broad = name_matched.select { |c| broad_umbrella_match?(c) }

      if explicit.size == 1
        explicit.first['orcid-id']
      elsif explicit.empty? && broad.size == 1
        broad.first['orcid-id']
      end
    end
  end
end
