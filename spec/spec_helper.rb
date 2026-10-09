# frozen_string_literal: true

require 'timeout'
require 'linkeddata' # for the live-ontology probe below; lib/queries.rb also requires it later

# Test env vars — set *before* requiring configuration.rb so its Dotenv.load
# (which never overwrites already-set ENV vars) can't pull in a developer's
# real .env secrets.
#
# CBGP_KB drives which copy of the ontology $ontology gets loaded from. This
# project deliberately puts almost no domain knowledge in code (see
# lib/dataset_classes.rb) so that non-programmer curators can add/change
# fields by editing the ontology alone — which means the ontology changes far
# more often than this codebase does. A frozen local snapshot alone would
# silently drift out of date (a 2026-07-09 bug slipped through exactly this
# way: 4 fields had been retyped live but the committed fixture still showed
# the old type). So resolution prefers the freshest source available and
# only falls back to the committed snapshot if neither is reachable:
#   1. A sibling ../CBGP-Ontology checkout, if this machine happens to have
#      one (fast, no network) - not guaranteed, since CBGP-Databases can be
#      checked out on its own.
#   2. The live ontology at https://w3id.org/CBGP-App (same URL production
#      uses), probed with a short timeout so offline dev doesn't hang.
#   3. spec/fixtures/cbgp-application-ontology.owl, the last-resort committed
#      snapshot, used only when neither of the above is available. Refresh it
#      occasionally with:
#        cp ../CBGP-Ontology/cbgp-application-ontology.owl spec/fixtures/
def resolve_ontology_source
  sibling = File.expand_path('../../CBGP-Ontology/cbgp-application-ontology.owl', __dir__)
  return sibling if File.exist?(sibling)

  live_url = 'https://w3id.org/CBGP-App'
  Timeout.timeout(5) { RDF::Repository.load(live_url) }
  live_url
rescue StandardError => e
  warn "[spec_helper] Live ontology unreachable (#{e.class}: #{e.message}) - " \
       'falling back to the committed fixture snapshot, which may be stale'
  File.expand_path('fixtures/cbgp-application-ontology.owl', __dir__)
end

ENV['CBGP_USERS']     ||= '{"test-admin":{"password":"test","role":"admin"},"test-user":{"password":"test","role":"user"}}'
ENV['CBGP_SECRET']    ||= 'test-secret-not-for-production-must-be-at-least-64-bytes-long-xxxx'
ENV['NOTIFY_TO']      ||= 'test@example.invalid'
ENV['NOTIFY_UN']      ||= 'test-user'
ENV['NOTIFY_PW']      ||= 'test-pass'
ENV['VIRTUOSO_HOST']         ||= 'localhost:8890'
ENV['VIRTUOSO_USER']         ||= 'test'
ENV['VIRTUOSO_PASS']         ||= 'test'
ENV['VIRTUOSO_HISTORY_HOST'] ||= 'localhost:8891'
ENV['CBGP_KB'] ||= resolve_ontology_source
# Charts use the built-in theme in specs, whatever theme/theme.yml a developer has.
ENV['CBGP_THEME_FILE'] ||= File.join(__dir__, 'fixtures', 'no-such-theme.yml')

# Normally defined in app/controllers/application_controller.rb; redefined
# here so lib/ files can be exercised standalone without booting the full
# Sinatra app. Tests that care about a specific language set
# Thread.current[:language] directly (see spec/support if that grows).
def current_language
  Thread.current[:language] || 'en'
end

require 'json' # normally pulled in by application_controller.rb before configuration.rb
require 'cgi'
require 'jsonpath'
require 'sanitize'
require 'rest-client'
require_relative '../app/controllers/configuration'
require_relative '../lib/core'
require_relative '../lib/queries'
require_relative '../lib/dataset_classes'
require_relative '../lib/helpers'
require_relative '../lib/triggers'
require_relative '../lib/questionnaire'
require_relative '../lib/history_queries'
require_relative '../lib/doi_registration_agency'
require_relative '../lib/publication_type_classifier'
require_relative '../lib/open_access_classifier'
require_relative '../lib/datacite_parser'
require_relative '../lib/crossref_parser'
require_relative '../lib/openaire_parser'
require_relative '../lib/personnel_matcher'
require_relative '../lib/loaders'
require_relative '../lib/related_records'
require_relative '../lib/mcp/server'
require_relative '../lib/mcp/records'
require_relative '../lib/mcp/theme'
require_relative '../lib/mcp/widgets/timeline'
Dir[File.join(__dir__, '../lib/mcp/tools/*.rb')].sort.each { |file| require file }

RSpec.configure do |config|
  config.expect_with :rspec do |expectations|
    expectations.include_chain_clauses_in_custom_matcher_descriptions = true
  end

  config.mock_with :rspec do |mocks|
    mocks.verify_partial_doubles = true
  end

  config.shared_context_metadata_behavior = :apply_to_host_groups
  config.filter_run_when_matching :focus
  config.order = :random
  Kernel.srand config.seed

  # Reset to English before every example so specs aren't order-dependent on
  # whatever language a previous example happened to leave set.
  config.before do
    Thread.current[:language] = 'en'
  end
end
