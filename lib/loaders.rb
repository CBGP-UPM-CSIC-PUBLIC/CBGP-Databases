# frozen_string_literal: true

module CBGP
  class Loaders
    # Public: Load a single DOI (existing behavior preserved)
    def self.load_doi(doi:, database: 'publication')
      messages = []
      # allpubs  = []

      warn "\n\n\nFETCHING DOI #{doi}\n\n\n"
      result = load_or_fetch_doi(doi: doi, database: database)

      if result[:existing]
        warn "DOI #{doi} already exists in database"
        messages << "DOI:#{doi} was already in database"

      elsif result[:pub]
        warn "Loaded and saved new publication for DOI #{doi}"
        messages << "DOI:#{doi} loaded and saved successfully"
      else
        warn "Failed to load DOI #{doi}"
        messages << "Failed to load DOI:#{doi}"
      end

      result[:pub] # Return the Dataset object (or nil)
    end

    # Average measured cost of CBGP::Parsers.mine_member_orcid for one
    # author: 6 HTTP round-trips to ORCID.org with politeness sleeps
    # between them. Confirmed live (2026-10-16), measured twice
    # independently on the same 605-author batch: 27m02s and 27m20s, both
    # landing at ~2.7s/author.
    ORCID_SEARCH_SECONDS_PER_AUTHOR = 2.7

    # Public: Bulk load multiple DOIs
    #
    # The ORCID.org mining step (CBGP::Parsers.mine_member_orcid) is never
    # run inline here, unlike the single-DOI path - at ~2.7s per author
    # needing a search, a bulk load of several DOIs could take minutes and
    # risk an HTTP/reverse-proxy timeout (confirmed live, 2026-10-16, the
    # same day this got wired in). Candidates are collected instead and
    # mined in a background Thread after this method returns, following
    # the existing fire-and-forget pattern already used elsewhere in this
    # app (app/controllers/routes.rb's MCP cache warm-up) - the caller gets
    # a job id to poll via CBGP::OrcidMiningJobs and a time estimate.
    def self.bulk_load_from_dois(dois:, database: 'publication')
      messages = []
      allpubs  = []
      pending_candidates = []

      normalized_dois = dois.to_s.split(/[, \t\n]+/).map(&:strip).reject(&:empty?).uniq

      # Loaded once for the whole batch, not once per DOI: matching a
      # publication's authors against CBGP personnel needs this index, and
      # reloading all of personnel from scratch for every single DOI is the
      # dominant cost of a bulk load (see lib/personnel_matcher.rb).
      member_index = CBGP::Parsers.load_member_index

      normalized_dois.each do |doi|
        warn "\n\n\nFETCHING DOI #{doi}\n\n\n"
        result = load_or_fetch_doi(doi: doi, database: database, member_index: member_index, mine_missing_orcids: false)

        if result[:existing]
          messages << "DOI:#{doi} was already in database"
        elsif result[:pub]
          allpubs << result[:pub]
          pending_candidates.concat(result[:pending_orcid_candidates] || [])
          messages << "DOI:#{doi} loaded and saved successfully"
        else
          messages << "Failed to load DOI:#{doi}"
        end
      end

      messages << 'No errors encountered during upload' if messages.none? { |m| m.include?('Failed') }

      # Dedup by member graph - the same orcid-less member can be a pending
      # candidate on more than one DOI in this same batch; no point
      # searching ORCID.org twice for them.
      unique_candidates = pending_candidates.uniq { |c| c[:graph] }
      job_id = nil
      estimated_seconds = 0
      if unique_candidates.any?
        estimated_seconds = (unique_candidates.size * ORCID_SEARCH_SECONDS_PER_AUTHOR).round
        job_id = CBGP::OrcidMiningJobs.create(total: unique_candidates.size)
        Thread.new { mine_pending_orcids(candidates: unique_candidates, job_id: job_id, database: database) }
      end

      [allpubs, messages, job_id, estimated_seconds]
    end

    # Background-thread body for the bulk path (see bulk_load_from_dois):
    # mines each pending candidate's ORCID, writes it to their member
    # record, then re-matches every publication that gained a new orcid so
    # the xref actually lands on the publication too - merging into
    # whatever's already there, never only writing when the field started
    # completely empty (that exact gate was a confirmed real bug in
    # utilities/rematch_xrefs_after_orcid_mining.rb until 2026-10-16: it
    # silently blocked every newly-mined orcid from ever reaching a
    # publication that already had one other resolved author).
    def self.mine_pending_orcids(candidates:, job_id:, database:)
      affected_dois = Set.new
      candidates.each do |c|
        # One candidate's failure (an ORCID.org timeout, a transient
        # network error) must not abandon the rest of the batch, nor leave
        # the job stuck at done: false forever - the bulk-load page polls
        # this status and would spin indefinitely.
        begin
          mined_orcid = CBGP::Parsers.mine_member_orcid(given: c[:given], family: c[:family])
        rescue StandardError => e
          warn "ORCID mining failed for #{c[:given]} #{c[:family]}: #{e.message}"
          mined_orcid = nil
        end

        if mined_orcid
          member_ds = CBGP::Dataset.load_from_graph(database: 'member', graph: c[:graph],
                                                    pre_fetched_primary_id: c[:graph].split('/').last)
          member_ds.orcid = mined_orcid
          CBGP::Dataset.write_to_db(dataset: member_ds, oldid: member_ds.primary_id)
          affected_dois << c[:doi]
        end
        CBGP::OrcidMiningJobs.record_result(job_id, found: !mined_orcid.nil?)
      end

      return if affected_dois.empty?

      fresh_member_index = CBGP::Parsers.load_member_index
      affected_dois.each do |doi|
        rematch_publication_xrefs(doi: doi, database: database, member_index: fresh_member_index)
      end
    rescue StandardError => e
      warn "Background ORCID mining job #{job_id} failed: #{e.message}"
    end

    def self.rematch_publication_xrefs(doi:, database:, member_index:)
      agency = CBGP::Parsers.resolve_doi_registration_agency(doi: doi)
      result = case agency
               when 'DataCite' then CBGP::Parsers.datacite_parser(doi: doi)
               when 'Crossref' then CBGP::Parsers.crossref_parser(doi: doi)
               else { pub: false, authors: [] }
               end
      result = CBGP::Parsers.openaire_parser(doi: doi) unless result[:pub]
      matched_orcids = CBGP::Parsers.match_authors_to_personnel(authors: result[:authors], member_index: member_index)
      return if matched_orcids.empty?

      graphs = execute_search(search_params: { 'publication_doi' => doi }, dataset_type: database)
      graph = graphs&.first
      return unless graph

      pub = CBGP::Dataset.load_from_graph(graph: graph, database: database,
                                          pre_fetched_primary_id: graph.split('/').last)
      existing = pub.cbgp_author_orcids.to_a
      merged = (existing + matched_orcids).uniq
      return if merged.sort == existing.sort

      pub.cbgp_author_orcids = merged
      pub.write_to_db
    end

    # Shared core logic: check existence → parse if new → write
    #
    # @param member_index [Array<Hash>, nil] pre-loaded personnel index (see
    #   CBGP::Parsers.load_member_index) to reuse across a bulk load; loaded
    #   here when nil (the single-DOI path) so match_authors_to_personnel
    #   and harvest_orcids_from_authors share the one load instead of each
    #   silently loading their own (confirmed live, 2026-10-16: that was
    #   happening on every single-DOI load before this).
    # @param mine_missing_orcids [Boolean] when true (the single-DOI path),
    #   search ORCID.org inline for any author who name-matches an existing
    #   orcid-less member. When false (the bulk path), skip the search -
    #   each candidate is returned in :pending_orcid_candidates instead, for
    #   the caller to mine in a background job. At ~2.7s per author, doing
    #   this inline for a bulk load risks an HTTP/reverse-proxy timeout
    #   (confirmed live, 2026-10-16) - a single-DOI load has at most a
    #   handful of authors, so it stays synchronous.
    def self.load_or_fetch_doi(doi:, database:, member_index: nil, mine_missing_orcids: true)
      # Strip an optional doi.org resolver prefix up front, once, so every
      # downstream use of `doi` (the dedupe search, the RA-resolution lookup,
      # and the DataCite/Crossref fetch URLs below) sees the bare DOI. Without
      # this, doi.org/Crossref happen to still resolve a doubled prefix (e.g.
      # "https://doi.org/https://doi.org/10.xxx") via their own lenient
      # routing, but that's accidental external behavior, not something this
      # code should depend on staying true.
      doi = doi.to_s.strip.sub(%r{\Ahttps?://(dx\.)?doi\.org/}i, '')

      # 1. Check if already exists. 'publication_doi' is the real questionclass
      # (was 'newpub4' - a stale reference that predates Sara's 2026-08
      # restructuring; the mismatch made this duplicate check a silent no-op
      # on every single load, found 2026-08-26 while testing a real bulk
      # load - see CHANGELOG).
      graphs = execute_search(search_params: { 'publication_doi' => doi }, dataset_type: database)

      if graphs&.any?
        graph = graphs.first
        warn "Found existing graph for DOI #{doi}: #{graph}"
        pub = CBGP::Dataset.load_from_graph(graph: graph, database: database)
        return { pub: pub, existing: true }
      end

      # 2. Not found → parse. Ask doi.org which agency registered this DOI so
      # we go straight to the richest matching source instead of guessing:
      # DataCite-registered DOIs go to datacite_parser, Crossref-registered
      # ones to crossref_parser. OpenAIRE aggregates both (and more), so it
      # remains the fallback when the agency is unknown or the preferred
      # parser comes back empty.
      agency = CBGP::Parsers.resolve_doi_registration_agency(doi: doi)
      result = case agency
               when 'DataCite'
                 CBGP::Parsers.datacite_parser(doi: doi)
               when 'Crossref'
                 CBGP::Parsers.crossref_parser(doi: doi)
               else
                 { pub: false, authors: [] }
               end

      result = CBGP::Parsers.openaire_parser(doi: doi) unless result[:pub]

      pub = result[:pub]
      return { pub: nil, existing: false } unless pub

      # enrich affiliations regardless of which parser found the core record
      CBGP::Parsers.openaire_affiliations(pub: pub, doi: doi)

      member_index ||= CBGP::Parsers.load_member_index

      # Cross-reference authors against existing CBGP personnel by ORCID (when
      # the source gave us one) or exact accent-insensitive name match
      # otherwise - never fuzzy, to avoid mis-attributing an outside
      # co-author's identity to a CBGP member.
      matched_orcids = CBGP::Parsers.match_authors_to_personnel(authors: result[:authors], member_index: member_index)

      # A name-matched member with no ORCID on file yet, whose own
      # self-asserted ORCID Crossref/DataCite already handed us on this
      # very publication, gets that ORCID written onto their record - see
      # harvest_orcids_from_authors's doc comment for why this is trusted
      # data, not a guess. Folded into this publication's own xref too, not
      # just left for the next load to pick up.
      harvested = CBGP::Parsers.harvest_orcids_from_authors(authors: result[:authors], member_index: member_index)
      harvested.each do |h|
        member_ds = CBGP::Dataset.load_from_graph(database: 'member', graph: h[:graph],
                                                  pre_fetched_primary_id: h[:graph].split('/').last)
        member_ds.orcid = h[:orcid]
        CBGP::Dataset.write_to_db(dataset: member_ds, oldid: member_ds.primary_id)
      end
      matched_orcids = (matched_orcids + harvested.map { |h| h[:orcid] }).uniq

      # Any author who name-matches an existing member with no ORCID at all
      # (not covered by the self-asserted harvest above) either gets mined
      # right now (single-DOI path) or handed back for the caller to mine
      # later (bulk path) - see CBGP::Parsers.mine_member_orcid and the
      # mine_missing_orcids param doc above.
      found_orcids, pending_orcid_candidates = resolve_or_defer_missing_orcids(
        authors: result[:authors], member_index: member_index, doi: doi, mine_missing_orcids: mine_missing_orcids
      )
      matched_orcids = (matched_orcids + found_orcids).uniq

      pub.cbgp_author_orcids = matched_orcids if pub.respond_to?(:cbgp_author_orcids=)

      # 3. Save it
      pub.write_to_db
      { pub: pub, existing: false, pending_orcid_candidates: pending_orcid_candidates }
    end

    # Returns [orcids_found_and_written, candidates_deferred_for_later] -
    # see load_or_fetch_doi's mine_missing_orcids param doc for why this
    # branches on it.
    def self.resolve_or_defer_missing_orcids(authors:, member_index:, doi:, mine_missing_orcids:)
      found = []
      pending = []
      (authors || []).each do |author|
        member = CBGP::Parsers.send(:find_member_by_name, member_index, author[:given], author[:family])
        next unless member
        next unless member[:orcid].to_s.strip.empty?

        unless mine_missing_orcids
          pending << { given: author[:given], family: author[:family], graph: member[:graph], doi: doi }
          next
        end

        mined_orcid = CBGP::Parsers.mine_member_orcid(given: author[:given], family: author[:family])
        next unless mined_orcid

        member_ds = CBGP::Dataset.load_from_graph(database: 'member', graph: member[:graph],
                                                  pre_fetched_primary_id: member[:graph].split('/').last)
        member_ds.orcid = mined_orcid
        CBGP::Dataset.write_to_db(dataset: member_ds, oldid: member_ds.primary_id)
        found << mined_orcid
      end
      [found, pending]
    end
  end
end
