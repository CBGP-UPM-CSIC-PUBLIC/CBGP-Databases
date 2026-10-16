# frozen_string_literal: true

require 'securerandom'

module CBGP
  # In-memory, process-local tracker for the background ORCID-mining job a
  # bulk DOI load kicks off (see lib/loaders.rb). Deliberately simple - no
  # job queue exists in this app (plain Sinatra, no Sidekiq/etc.); the
  # existing precedent is a bare `Thread.new` fire-and-forget (app/
  # controllers/routes.rb's MCP cache warm-up). This adds the first bit of
  # progress tracking for one of those background threads, so the bulk-
  # load page can poll and show real progress instead of leaving the user
  # with no idea whether anything is still happening.
  #
  # In-memory means a job's status is lost if the app process restarts
  # mid-run - acceptable here, since this only tracks a transient
  # convenience ("how much progress has the ORCID search made"), not state
  # that must survive a restart; the mining work itself (writing member
  # orcids, updating publication xrefs) is already safely persisted to the
  # database as it happens, independent of this tracker.
  class OrcidMiningJobs
    @jobs = {}
    @mutex = Mutex.new

    def self.create(total:)
      id = SecureRandom.uuid
      @mutex.synchronize do
        @jobs[id] = { total: total, searched: 0, found: 0, done: total.zero?, started_at: Time.now }
      end
      id
    end

    def self.record_result(id, found:)
      @mutex.synchronize do
        job = @jobs[id]
        next unless job

        job[:searched] += 1
        job[:found] += 1 if found
        job[:done] = job[:searched] >= job[:total]
      end
    end

    def self.status(id)
      @mutex.synchronize { @jobs[id]&.dup }
    end
  end
end
