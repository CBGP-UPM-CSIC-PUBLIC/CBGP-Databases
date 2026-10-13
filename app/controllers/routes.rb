# frozen_string_literal: false

require 'compass' # gives us sass/scss
require 'json'
require 'sinatra/flash'
require_relative '../../lib/core'

def set_routes
  # Compass.add_project_configuration(File.join(Sinatra::Application.root, "config", "compass.rb"))

  configure do
    set :bind, '0.0.0.0'  # Bind to all interfaces
    set :port, 4567       # Explicitly set the port
    set :server_settings, timeout: 180
    set :root, File.dirname(__FILE__)
    set :views, proc { File.join(root, '../views') }
    set :public_folder, File.join(root, '../public')
    set :haml, { format: :html5, escape_html: true }
    set :scss, { style: :compact, debug_info: false }
    set :static_cache_control, [:public, { max_age: 0 }]
    set :session_secret, CBGP_SECRET
    enable :sessions
    use Rack::Session::Cookie, key: 'rack.session', secret: CBGP_SECRET
  end

  get '/cbgp/stylesheets/:name.css' do
    content_type 'text/css', charset: 'utf-8'
    scss(:"stylesheets/#{params[:name]}")
  end

  # ----------------------------------------------------------------------------
  # ----------------------------------------------------------------------------
  # ----------------------------------------------------------------------------
  # ----------------------------------------------------------------------------
  # ----------------------------------------------------------------------------
  #  LOGIN FUNCTIONS

  get '/cbgp/login' do
    erb :login
  end

  post '/cbgp/login' do
    username = params[:username]
    password = params[:password]

    user_data = USERS[username]
    if user_data && user_data['password'] == password
      session[:username] = username
      role = user_data['role'] # 'admin' or 'user'
      session[:role] = role
      if role == 'user'
        redirect '/cbgp/user-dashboard'
      else
        redirect '/cbgp/dashboard'
      end
    else
      @error = 'Invalid username or password.'
      erb :login
    end
  end

  get '/cbgp/logout' do
    session.clear
    redirect '/cbgp/login'
  end

  before do
    public_paths = [
      '/', # Usually the login page
      '/cbgp/login', # Login page
      '/cbgp/stylesheets/cbgp.css', # Login page
      '/logout', # Optional: logout route
      '/set_language', # Add the new route to public paths
      '/cbgp/active-emails', # emails
      '/cbgp/active-members' # Amembers
      # '/cbgp/user-dashboard' # Add the new route to public paths
    ]

    # List of path prefixes that require admin (read/write) privileges
    admin_required_prefixes = [
      '/cbgp/dashboard', # Form submission / write
      '/cbgp/validate-dataset',   # Form submission / write
      '/cbgp/loaders/load',       # DOI loader (writes data)
      '/cbgp/publications/bulk'   # Bulk publication load (writes data)
    ]
    # Skip authentication check for public paths
    return if public_paths.include?(request.path_info)
    # The MCP endpoint is for agents, not browsers: it checks its own bearer token (app/controllers/mcp_routes.rb)
    return if request.path_info == '/mcp'

    # All other paths require login
    halt(401, erb(:unauthorized)) unless session[:username]

    # Additional role check: write operations require 'admin' role
    if admin_required_prefixes.any? { |prefix| request.path_info.start_with?(prefix) } && !(session[:role] == 'admin')
      halt(403, 'Forbidden: Admin privileges required for this action.')
    end

    cache_control :public, :must_revalidate, max_age: 0
    $language = session[:language] || params[:language] || 'en'
  end

  post '/set_language' do
    new_lang = params['language']&.strip&.downcase
    if %w[en es].include?(new_lang)
      session[:language] = new_lang
      warn "Language set to '#{new_lang}' for session #{session.object_id}"
    else
      session[:language] = 'en' # Fallback
    end

    status 204 # No Content – clean for fetch() + reload
  end

  get '/cbgp/refresh' do # when the ontology is updated...
    $ontology = RDF::Repository.load(CBGP_KB) # set in configuration.rb and/or in docker-compose
    # Reloading $ontology alone doesn't invalidate the per-form-type field
    # caches, so without this a refresh would keep serving stale field
    # definitions (e.g. a newly-added currency field wouldn't show up)
    # until the whole app process restarted.
    CBGP::Dataset.clear_caches!
    Questionnaire.clear_cache!
    CBGP::Triggers.clear_cache!
    CBGP::UIText.clear_cache! # interface texts are ontology labels too
    Thread.new { Mcp::Records.warm_up } unless ENV['MCP_TOKEN'].to_s.strip.empty? # the AI agent's own ontology cache starts empty again
    redirect '/cbgp/dashboard'
  end
  # ----------------------------------------------------------------------------
  # ----------------------------------------------------------------------------
  # ----------------------------------------------------------------------------
  # ----------------------------------------------------------------------------
  # ----------------------------------------------------------------------------
  # Main Dashboard
  get '/' do
    redirect '/cbgp/dashboard'
  end

  get '/cbgp' do
    redirect '/cbgp/dashboard'
  end

  get '/cbgp/dashboard' do
    @databases = get_databases(type: 'Core')
    # What can be queried is what can be added PLUS one all-forms entry per
    # dbname several forms share; those are search scopes, never offered for adding.
    @query_databases = @databases + shared_dbname_entries(@databases)
    erb :dashboard
  end

  get '/cbgp/user-dashboard' do
    @databases = get_databases(type: 'UserFacing')
    erb :user_dashboard
  end

  post '/cbgp/databases' do
    form = params[:form] # database is actually the form name TODO update all cases of this
    redirect "/cbgp/dataset/#{form}"
    halt 422
  end
  post '/cbgp/user-databases' do
    form = params[:form]
    redirect "/cbgp/dataset/user-database/#{form}"
    halt 422
  end

  # ----------------------------------------------------------------------------
  # ----------------------------------------------------------------------------
  # ----------------------------------------------------------------------------
  # ----------------------------------------------------------------------------
  # ----------------------------------------------------------------------------

  # create the empty form for USERS
  # USERS
  # USERS
  # USERS
  # USERS
  # USERS
  # USERS
  # USERS
  # USERS
  get '/cbgp/dataset/user-database/:form' do
    @form = params[:form]
    @database = get_dbname_for_form(form: @form)
    @mode = 'edit'
    @questionnaire = generate_questionnaire(questionnaire_type: @form) # questionnaire has all fields and possible answers
    # may have more fields than the form itself renders
    # type: @form (NOT @database) - @database is the shared storage dbname
    # (e.g. "project"), which is no longer itself a valid ontology class
    # since Sara's project-fields restructuring split it into several
    # specific forms; CBGP::Dataset.new needs the real form class to look
    # up fields at all.
    @entry = CBGP::Dataset.new_with_defaults(type: @form, form: @form)
    halt erb :user_dataset, layout: :database_layout
  end

  # the form has been filled - now validate it
  post '/cbgp/validate-user-dataset/:database' do
    # :database here is the dbname (e.g. "project") the User form was posted
    # under — the same value used to write/look up the record. It is NOT the
    # restricted UserFacing questionnaire code (e.g. "userproject"), so it
    # must not be used to rebuild @questionnaire: that would silently swap in
    # the full Admin field set on redisplay. The true form code is carried
    # separately via the hidden form_class field (see user_dataset.erb).
    @database = params[:database]
    @form = params['form_class'].to_s.strip
    @form = @database if @form.empty? # defensive fallback for a stale/hand-crafted request missing the hidden field
    @questionnaire = generate_questionnaire(questionnaire_type: @form) # create the fields that will carry the answers provided
    @mode = 'edit' # the HTML form has a query mode and an edit mode.  Select the edit mode

    begin
      # form: @form (NOT @database) - this is what load_from_params_and_write
      # uses to look up local:requires-field for THIS specific form, so
      # "required" validation matches whichever form was actually used, not
      # just whichever other form happens to share the same dbname.
      @entry = CBGP::Dataset.load_from_params_and_write(params: params, form: @form)
    rescue CBGP::Dataset::ValidationError => e
      @validation_errors = e.errors
      # type: @form (NOT params['database']) - same dbname-vs-form distinction
      # as everywhere else in this route.
      @entry = CBGP::Dataset.new_from_raw_params(type: @form, params: params)
      halt erb :user_dataset, layout: :database_layout
    end

    # Every submission through this route came from a UserFacing form, so
    # check for an ontology-declared form-level trigger (local:has-triggers
    # on @form - see lib/triggers.rb). If this form doesn't have one
    # configured yet, on_no_form_trigger preserves the original,
    # unconditional "admins get a heads-up" behavior exactly as before -
    # form-agnostic, so this covers any future UserFacing form (e.g.
    # incoming Staff registration) with no changes needed here.
    link = "#{request.base_url}/cbgp/dataset/#{@database}/#{@entry.primary_id}"
    CBGP::Triggers.check_and_fire(
      dataset: @entry,
      on_no_form_trigger: -> { notify_new_user_submission(dataset: @entry, link: link) }
    )

    halt erb :thankyou, layout: :database_layout
  end

  # # POST route: lookup by identifier submitted in form body
  # post '/cbgp/dataset/user-database/:database' do
  #   load_dataset_for_edit(database: params[:database], primary_id: params[:primary_id]) # look to helpers
  # end

  # ADMINSTRATORS
  # ADMINSTRATORS
  # ADMINSTRATORS
  # ADMINSTRATORS
  # ADMINSTRATORS
  # ADMINSTRATORS
  # ADMINSTRATORS
  # create the empty form for ADMINSTRATORS
  get '/cbgp/dataset/:database' do
    @form = params[:database]
    @database = get_dbname_for_form(form: @form)
    @mode = 'edit'
    # @form (the specific form class, e.g. "personnel_project") drives which
    # fields are shown - @database (the shared dbname, e.g. "project") must
    # NOT be used here, or two forms sharing one dbname would both render
    # whichever form's section happens to match the dbname string.
    @questionnaire = generate_questionnaire(questionnaire_type: @form) # questionnaire has all fields and possible answers
    # type: @form (NOT @database) - see the same note on the User-facing
    # route above; @database (the shared storage dbname) is no longer
    # itself a valid ontology class to build a Dataset from.
    @entry = CBGP::Dataset.new_with_defaults(type: @form, form: @form)
    @entry.prefill_references(params) # e.g. a member's "add a new commitment" link
    halt erb :dataset, layout: :database_layout
  end

  # POST route: lookup by identifier submitted in form body
  post '/cbgp/dataset/:database' do
    load_dataset_for_edit(database: params[:database], primary_id: params[:primary_id]) # look to helpers
  end

  # GET route: direct access by primary_id (UUID) in URL – perfect for links from search results
  get '/cbgp/dataset/:database/:primary_id' do
    load_dataset_for_edit(database: params[:database], primary_id: params[:primary_id]) # look to helpers
  end

  # GET route: direct access by primary_id (UUID) in URL – perfect for links from search results
  get '/cbgp/dataset/delete/:database/:primary_id' do
    delete_dataset(database: params[:database], primary_id: params[:primary_id]) # look to helpers
  end

  post '/cbgp/query-dataset/:database/delete-multiple' do
    @database = params[:database]
    selected_ids = params['selected_ids'] || []

    halt 400, 'No records selected' if selected_ids.empty?

    # Perform deletes
    selected_ids.each do |primary_id|
      next if primary_id.to_s.strip.empty?

      graphres = retrieve_dataset_graph_query(primary_id: primary_id)
      next if graphres.empty?

      graphuri = graphres.first[:g].to_s
      delete_dataset_query(oldid: graphuri)
    end

    # Refresh results using saved session search (same as single delete)

    last_search = session[:last_search]
    if last_search && last_search[:database] == @database
      search_params = last_search[:params] # Now it's plain Hash
      warn "Re-running search with params: #{search_params.inspect}" # debug

      @fields = search_fields_for(@database)
      note_search_kind(search_params)
      graphuris = execute_search(search_params: search_params, dataset_type: @database)

      @datasets = []
      graphuris.each do |graphuri|
        @datasets << CBGP::Dataset.load_from_graph(graph: graphuri, database: @database)
      end

      erb :search_dataset_resultform, layout: :database_layout
    else
      redirect '/cbgp/dashboard' # Fallback if no search context
    end
  end
  # the form has been filled - now validate it
  post '/cbgp/validate-dataset/:database' do
    # :database here is the dbname (e.g. "project"), NOT the specific form
    # class (e.g. "personnel_project" vs "project") - dataset.erb's form
    # action posts to /cbgp/validate-dataset/<%= @database %>, so this URL
    # segment is always the dbname. Previously this line wrongly assigned it
    # to @form directly (both happened to be the same string until a second
    # form started sharing the "project" dbname) - now the true form class is
    # carried separately via the hidden form_class field (see dataset.erb),
    # the same fix already applied to the User-facing route above.
    @database = params[:database]
    @form = params['form_class'].to_s.strip
    @form = @database if @form.empty? # defensive fallback for a stale/hand-crafted request missing the hidden field
    @questionnaire = generate_questionnaire(questionnaire_type: @form) # create the fields that will carry the answers provided
    @mode = 'edit' # the HTML form has a query mode and an edit mode.  Select the edit mode

    begin
      # form: @form (NOT @database) - see the comment on the User-facing
      # route above for why this distinction matters for required-field
      # validation.
      @entry = CBGP::Dataset.load_from_params_and_write(params: params, form: @form)
      # Inside the begin block, right after the successful write - this
      # route's rescue branch (unlike the User-facing route's) falls
      # through to the shared `halt erb :dataset` below rather than halting
      # immediately, so placing this after the whole begin/rescue would
      # incorrectly also run it on a validation failure.
      #
      # check_form_level: false - this route can also create a brand-new
      # record directly (GET /cbgp/dataset/:database renders a blank
      # dataset.erb that posts here), which is technically a "creation" the
      # same as a User-facing submission is. A form-level trigger means "a
      # User registered themselves" - the admin team doesn't need notifying
      # when THEY create a record - so form-level triggers are deliberately
      # skipped here regardless of whether the ontology has one configured
      # for this form. Answer-level triggers (e.g. Damaris approving a
      # record) are NOT affected by this flag and still fire normally.
      CBGP::Triggers.check_and_fire(dataset: @entry, check_form_level: false)
      @related_panels = CBGP::RelatedRecords.panels_for(entry: @entry, type: @database)

      # Editing an existing record that was reached from a search: go back to
      # those results (the record just changed is in them, and the next thing an
      # administrator wants is usually a neighbouring record - e.g. the sister
      # commitment that holds the rest of a split) rather than redisplaying the
      # same edit form. A brand-new record, or an edit not reached via a search,
      # keeps showing the saved record. Advisory panel warnings (e.g. "active
      # funding totals 91, expected 100") ride along as a flash, since the
      # results page has no panel of its own to show them in.
      search_form = [@form, @database].find { |f| session[:last_search] && session[:last_search][:database] == f }
      if search_form && !params['primary_id'].to_s.strip.empty?
        flash[:notice] = 'Record saved.'
        warnings = (@related_panels || []).select(&:warning).flat_map do |panel|
          CBGP::RelatedRecords.warning_messages(panel).map { |m| "#{panel.subject || panel.title}: #{m}" }
        end
        flash[:warning] = warnings.join(' ') unless warnings.empty?
        redirect "/cbgp/last-search/#{Rack::Utils.escape_path(search_form)}"
      end

      # Otherwise show the saved record at its own address, not at this form-handler
      # URL (a POST has no address worth keeping: bookmarking it, or pressing
      # refresh, would not give the record back). The panel warnings are drawn by
      # the record page itself, so only the confirmation rides along.
      flash[:notice] = 'Record saved.'
      redirect "/cbgp/dataset/#{ERB::Util.url_encode(@form)}/#{ERB::Util.url_encode(@entry.primary_id.to_s)}"
    rescue CBGP::Dataset::ValidationError => e
      @validation_errors = e.errors
      # type: @form (NOT params['database']) - same dbname-vs-form distinction
      # as everywhere else in this route.
      @entry = CBGP::Dataset.new_from_raw_params(type: @form, params: params)
    end

    halt erb :dataset, layout: :database_layout
  end

  #
  # QUERY FORMS
  # QUERY FORMS
  # QUERY FORMS
  # QUERY FORMS
  # QUERY FORMS
  # QUERY FORMS
  # QUERY FORMS
  # QUERY FORMS
  # QUERY FORMS
  # QUERY FORMS
  # QUERY FORMS
  # QUERY FORMS
  # QUERY FORMS
  # QUERY FORMS

  # Ensure the full route context is included
  get '/cbgp/search-dataset/:database' do
    @database = params[:database]
    @questionnaire = generate_questionnaire(questionnaire_type: @database, only_fields: search_field_restriction(@database))
    @entry = CBGP::Dataset.new(type: @database)
    @mode = 'search'
    halt erb :search_dataset_inputform, layout: :database_layout
  end

  get '/cbgp/search-dataset' do # creates the search page iwth database in the POST body
    @database = params[:database]
    halt 400, 'Database parameter is required' unless @database
    @questionnaire = generate_questionnaire(questionnaire_type: @database, only_fields: search_field_restriction(@database))
    @entry = CBGP::Dataset.new(type: @database)
    @mode = 'search'
    halt erb :search_dataset_inputform, layout: :database_layout
  end

  # Re-runs the search this session last ran on :database and shows its
  # results - where saving or deleting a record lands. Falls back to the
  # search form when this session has no search for that database (e.g. the
  # session expired), rather than a dead end.
  get '/cbgp/last-search/:database' do
    halt erb(:search_dataset_resultform, layout: :database_layout) if render_last_search_results(database: params[:database])

    redirect "/cbgp/search-dataset/#{Rack::Utils.escape_path(params[:database])}"
  end

  # Answers GET as well as POST: the search form posts, while every value
  # shown on a result page is a plain link that GETs the same search with
  # "#{questionclass}__exact=1" (see search_link_html). One handler, so a link
  # and a typed search can never drift apart.
  %i[get post].each do |verb|
    public_send(verb, '/cbgp/query-dataset/:database') do
      @database = params[:database]

      # The search form posts, but a POST has no address worth keeping: bookmarking its
      # results page (or pressing refresh) would not run the search again. So a posted
      # search is answered with a redirect to the same search as a plain link holding
      # only the boxes that were filled in - the one URL that can be bookmarked, shared
      # and re-run later (a "today" in it is read on the day it is opened).
      if request.post?
        query = Rack::Utils.build_nested_query(compact_search_params(to_plain_hash(params.except('database').to_h)) || {})
        redirect "/cbgp/query-dataset/#{ERB::Util.url_encode(@database)}#{query.empty? ? '' : "?#{query}"}"
      end

      @questionnaire = generate_questionnaire(questionnaire_type: @database)
      @fields = search_fields_for(@database) # Cached

      search_params = params.except('database')
      note_search_kind(search_params)
      graphuris = execute_search(search_params: search_params, dataset_type: @database)

      # BATCH 1: All primary_ids
      primary_ids_by_graph = batch_retrieve_dataset_ids(graph_uris: graphuris)

      # BATCH 2: All details (already batched)
      all_details = fetch_datasets_raw_data(graph_uris: graphuris, database: @database)

      # Match details to graphs (preserve order)
      details_by_graph = all_details.each_with_object({}) do |detail_hash, hash|
        hash[detail_hash[:dataset]] = detail_hash
      end

      @datasets = graphuris.map do |graphuri|
        CBGP::Dataset.load_from_graph(
          graph: graphuri,
          database: @database,
          pre_fetched_details: details_by_graph[graphuri],
          pre_fetched_primary_id: primary_ids_by_graph[graphuri]
        )
      end

      @result_warnings = CBGP::RelatedRecords.result_warnings(datasets: @datasets, type: @database)
      @record_forms = record_forms_for_results(graphuris: graphuris, datasets: @datasets)

      plain_params = to_plain_hash(search_params.to_h) # Sinatra params object doesn't clone easily, so this makes it a hash
      session[:last_search] = {
        database: @database,
        params: plain_params
      }

      erb :search_dataset_resultform, layout: :database_layout
    end
  end

  # "Time machine" API: duplicates query-dataset's request shape (arbitrary
  # questionclass => value params for exact-match facets; questionclass =>
  # {start:, end:} for date-range facets, same nested-param convention the
  # search form already uses) but resolves against the SCD Type 2 history
  # repository via lib/history_queries.rb's filter_snapshots_during instead
  # of execute_search, and returns JSON-LD/TriG instead of rendering HTML —
  # a real API response, not a page, so it's directly callable from
  # anything that speaks HTTP (a notebook, a script in any language, a
  # future plugin), not just this app's own views.
  #
  # An optional sum_field param additionally sums that numeric field across
  # the matches (local:totalAmount in the response) — omit it for a plain
  # "what matched" result.
  #
  # @see lib/history_queries.rb#temporal_search_result
  post '/cbgp/query-history/:database' do
    database = params[:database]
    format = (params[:format] || 'jsonld').to_s
    halt 400, { error: 'format must be jsonld or trig' }.to_json unless %w[jsonld trig].include?(format)

    search_params = to_plain_hash(params.except('database', 'format', 'sum_field').to_h)
    # query-dataset's search form (and session[:last_search], which replays
    # those same params) may carry "#{questionclass}__not" negation flags -
    # meaningless here since this route hand-rolls facets/date_ranges rather
    # than going through build_search_query. Left in, a stray flag would
    # become its own bogus, unmatchable facet and force zero results.
    search_params.reject! { |k, _v| k.to_s.end_with?('__not', '__exact') }
    facets = {}
    date_ranges = {}
    search_params.each do |field, value|
      if value.is_a?(Hash)
        date_ranges[field] = { start: value['start'], end: value['end'] }
      elsif !value.to_s.strip.empty?
        facets[field] = value
      end
    end

    repo = temporal_search_result(form_type: database, facets: facets, date_ranges: date_ranges,
                                  sum_field: params[:sum_field])

    content_type(format == 'jsonld' ? 'application/ld+json' : 'application/trig')
    repo.dump(format.to_sym, prefixes: time_machine_prefixes)
  end

  # "Time machine" API: the complete version history of one record, resolved
  # by an identifying field (e.g. "give me the full history of member ORCiD
  # X from creation until today") — every edit/delete snapshot plus the
  # current state if it still exists, in order.
  #
  # @see lib/history_queries.rb#record_history_result
  get '/cbgp/history/:database/:questionclass/:value' do
    format = (params[:format] || 'jsonld').to_s
    halt 400, { error: 'format must be jsonld or trig' }.to_json unless %w[jsonld trig].include?(format)

    repo = record_history_result(form_type: params[:database], questionclass: params[:questionclass],
                                 value: params[:value])
    if repo.nil?
      halt 404,
           { error: "No #{params[:database]} record found with #{params[:questionclass]} = #{params[:value]}" }.to_json
    end

    content_type(format == 'jsonld' ? 'application/ld+json' : 'application/trig')
    repo.dump(format.to_sym, prefixes: time_machine_prefixes)
  end

  # Exposes the facet/possible-values metadata already used internally to
  # render add/edit/search forms (CBGP::Dataset.fields_for +
  # get_answer_block_query, lib/queries.rb) as a standalone API — lets an
  # external UI (or the query-history endpoint's own caller) discover what
  # fields exist for a form and, for controlled-vocabulary fields, what
  # values are legal, without having to scrape an HTML form.
  get '/cbgp/facets/:form_type' do
    content_type :json

    fields = CBGP::Dataset.fields_for(params[:form_type])
    facets = fields.map do |f|
      entry = {
        questionclass: f[:questionclass],
        label: f[:label],
        class: f[:class],
        cardinality: f[:cardinality],
        widget: f[:widget]
      }
      if controlled_vocabulary_field?(f)
        ablockid = f[:answers].to_s.split('#').last
        entry[:values] = get_answer_block_query(ablockid: ablockid).map do |r|
          { id: r[:aid].to_s.split('#').last, label: r[:label].to_s }
        end
      end
      entry
    end

    { form_type: params[:form_type], facets: facets }.to_json
  end

  #   GROK CODE FOR SUGGESTION ENDPOINT
  #   GROK CODE FOR SUGGESTION ENDPOINT
  #   GROK CODE FOR SUGGESTION ENDPOINT
  #   GROK CODE FOR SUGGESTION ENDPOINT
  #   GROK CODE FOR SUGGESTION ENDPOINT
  # Typeahead suggestion endpoint for cross-reference fields.
  #
  # Called by the JavaScript in _reference_typeahead.erb as the user types.
  # Returns a JSON array of +{ value, label }+ objects where:
  #   - +value+ is the field to be stored (e.g. ORCiD)
  #   - +label+ is the human-readable text shown in the dropdown (e.g. surname)
  #
  # Query parameters:
  #   @param q            [String] partial search string (required, min 2 chars
  #     enforced client-side)
  #   @param via          [String] questionclass of the stored-value field
  #     (e.g. +"member_orcid"+); omit for standard typeahead where value==label
  #   @param label_method [String] questionclass of the display field
  #     (e.g. +"member_surnames"+); falls back to +via+ field when omitted
  #
  # @return [String] JSON array, or 400 JSON error if +target+ or +q+ is blank
  get '/cbgp/reference/suggest/:target' do
    content_type :json

    target = params[:target]
    q      = params[:q].to_s.strip
    via    = params[:via].to_s.strip
    via    = nil if via.empty?
    label  = params[:label_method].to_s.strip
    label  = nil if label.empty?

    halt 400, { error: 'Missing params' }.to_json if target.empty? || q.empty?

    suggestions = CBGP::Dataset.fetch_reference_suggestions(
      target_form: target,
      limit: 20,
      search_query: q,
      via_class: via,
      label_method: label
    )
    suggestions.map { |s| { value: s[:value], label: s[:label] } }.to_json
  end

  # Reverse of the suggest endpoint above: given a value already stored on a
  # cross-reference field (e.g. an ORCiD saved on a previous visit, with no
  # label cached client-side), returns that record's human-readable label -
  # used by _reference_typeahead.erb to show a name alongside a stored xref
  # value, not just the raw stored value.
  #
  # Query parameters:
  #   @param via          [String] questionclass of the field the value is
  #     stored against (required), e.g. +"member_orcid"+
  #   @param label_method [String] questionclass of the field to display;
  #     falls back to the +via+ field itself when omitted
  #   @param value        [String] the stored value to look up (required)
  #
  # @return [String] JSON +{ label: String|nil }+, or 400 JSON error if
  #   +target+, +via+, or +value+ is blank
  get '/cbgp/reference/label/:target' do
    content_type :json

    target = params[:target]
    via    = params[:via].to_s.strip
    label  = params[:label_method].to_s.strip
    value  = params[:value].to_s.strip

    halt 400, { error: 'Missing params' }.to_json if target.empty? || via.empty? || value.empty?

    { label: CBGP::Dataset.fetch_reference_label(target_form: target, via_class: via, label_method: label,
                                                 value: value) }.to_json
  end

  # LOADERS
  # LOADERS
  # LOADERS
  # LOADERS
  # LOADERS
  # LOADERS
  # LOADERS
  # LOADERS
  # LOADERS
  # LOADERS
  # LOADERS
  # LOADERS
  # LOADERS
  # LOADERS

  # GET route: direct access by primary_id (UUID) in URL – perfect for links from search results
  post '/cbgp/loaders' do
    type = params['loader']
    halt erb :doi_loader, layout: :database_layout if type.to_s == 'DOI'
  end

  post '/cbgp/loaders/load' do # this routine presumes it is always a DOI
    warn 'loading publication'
    doi = params['doi'] # this routine presumes it is always a DOI
    @database = params['database'] || 'publication'
    warn "database type #{@database}"
    @entry = CBGP::Loaders.load_doi(doi: doi)
    @questionnaire = generate_questionnaire(questionnaire_type: @database) # create the fields that will carry the answers provided
    @mode = 'edit' # the HTML form has a query mode and an edit mode.  Select the edit mode
    halt erb :dataset, layout: :database_layout
  end

  post '/cbgp/publications/bulk' do
    dois = params[:dois]
    # creates a shared @messages variable for errors
    _allpubs, @messages = CBGP::Loaders.bulk_load_from_dois(dois: dois) if dois
    halt erb :bulkpubs
  end

  get '/cbgp/publications/bulk' do
    halt erb :bulkpubs
  end

  ################# DUMPERS
  ################# DUMPERS
  ################# DUMPERS
  ################# DUMPERS
  ################# DUMPERS
  ################# DUMPERS
  ################# DUMPERS
  ################# DUMPERS
  ################# DUMPERS
  ################# DUMPERS
  ################# DUMPERS
  ################# DUMPERS
  ################# DUMPERS
  ################# DUMPERS
  ################# DUMPERS

  get '/cbgp/active-members' do # creates the search page iwth database in the POST body
    $language = 'en' # rubocop:disable Style/GlobalVars
    @database = 'member'
    @questionnaire = generate_questionnaire(questionnaire_type: @database)
    @entry = CBGP::Dataset.new(type: @database)
    # 'mem17' was a stale, pre-restructuring ontology fragment for this
    # field (found 2026-08-26 - the /cbgp/active-members and
    # /cbgp/active-emails feeds silently returned zero members ever since
    # Sara's ontology restructuring renamed it). 'member_status' is the
    # current real questionclass; verified live against fields_for('member').
    memberstatus = 'member_status'
    statusresponse = 'active'
    params = { memberstatus => statusresponse }

    graphuris = execute_search(search_params: params, dataset_type: @database)

    $language = 'es' # switch to spanish for Gonzalo's pipeline # rubocop:disable Style/GlobalVars
    # BATCH 1: All primary_ids
    primary_ids_by_graph = batch_retrieve_dataset_ids(graph_uris: graphuris)
    # BATCH 2: All details (already batched)
    all_details = fetch_datasets_raw_data(graph_uris: graphuris, database: @database)

    # Match details to graphs (preserve order)
    details_by_graph = all_details.each_with_object({}) do |detail_hash, hash|
      hash[detail_hash[:dataset]] = detail_hash
    end

    @datasets = graphuris.map do |graphuri|
      CBGP::Dataset.load_from_graph(
        graph: graphuri,
        database: @database,
        pre_fetched_details: details_by_graph[graphuri],
        pre_fetched_primary_id: primary_ids_by_graph[graphuri]
      )
    end
    # Alphabetical by surname; unaccent first so e.g. "Álvarez" sorts with
    # "A" rather than after "Z" (same helper used for accent-insensitive
    # search, see lib/queries.rb).
    @datasets.sort_by! { |ds| unaccent(ds.surname.to_s).downcase }

    content_type 'application/xml', charset: 'utf-8'
    #    content_type 'text/plain', charset: 'utf-8'
    halt erb :xmlmembers
  end

  get '/cbgp/active-emails' do # creates the search page iwth database in the POST body
    $language = 'en' # rubocop:disable Style/GlobalVars
    @database = 'member'
    @questionnaire = generate_questionnaire(questionnaire_type: @database)
    @entry = CBGP::Dataset.new(type: @database)
    # 'mem17' was a stale, pre-restructuring ontology fragment for this
    # field (found 2026-08-26 - the /cbgp/active-members and
    # /cbgp/active-emails feeds silently returned zero members ever since
    # Sara's ontology restructuring renamed it). 'member_status' is the
    # current real questionclass; verified live against fields_for('member').
    memberstatus = 'member_status'
    statusresponse = 'active'
    params = { memberstatus => statusresponse }

    graphuris = execute_search(search_params: params, dataset_type: @database)

    $language = 'es' # switch to spanish for Gonzalo's pipeline # rubocop:disable Style/GlobalVars
    # BATCH 1: All primary_ids
    primary_ids_by_graph = batch_retrieve_dataset_ids(graph_uris: graphuris)
    # BATCH 2: All details (already batched)
    all_details = fetch_datasets_raw_data(graph_uris: graphuris, database: @database)

    # Match details to graphs (preserve order)
    details_by_graph = all_details.each_with_object({}) do |detail_hash, hash|
      hash[detail_hash[:dataset]] = detail_hash
    end

    @datasets = graphuris.map do |graphuri|
      CBGP::Dataset.load_from_graph(
        graph: graphuri,
        database: @database,
        pre_fetched_details: details_by_graph[graphuri],
        pre_fetched_primary_id: primary_ids_by_graph[graphuri]
      )
    end
    content_type 'application/xml', charset: 'utf-8'
    #    content_type 'text/plain', charset: 'utf-8'
    halt erb :xmlemail
  end

  ################# HELPERS
  ################# HELPERS
  ################# HELPERS
  ################# HELPERS
  ################# HELPERS
  ################# HELPERS
  ################# HELPERS
  ################# HELPERS
  ################# HELPERS
  ################# HELPERS
  ################# HELPERS
  ################# HELPERS
  ################# HELPERS
  #
  ## Merged handling for loading existing datasets (both by direct primary_id via GET and by identifier via POST)
  # The core logic is extracted into a helper method for full DRY compliance.
  # Both routes now delegate to the same code path.
  # - POST remains for form-based lookup (e.g., entering a DOI or other identifier)
  # - GET remains for direct linkability from search results (using the internal primary_id UUID)
  # The helper automatically detects special identifier types (e.g., DOI for publications) and routes accordingly.

  before do
    Thread.current[:language] = session[:language] || 'en'
  end

  helpers do # rubocop:disable Metrics/BlockLength
    def current_language # rubocop:disable Lint/NestedMethodDefinition
      Thread.current[:language] || 'en'
    end

    def load_dataset_for_edit(database:, primary_id:) # rubocop:disable Lint/NestedMethodDefinition
      halt 400, 'primary Identifier required' if primary_id.to_s.strip.empty?

      @database = database # need instane variable for ERBs
      @mode = 'edit'
      @questionnaire = generate_questionnaire(questionnaire_type: @database)

      # for known identifiers, cleanse it (e.g. remove "doi:" from DOIs)
      # If identifier_type returns nil/nothing special, fall back to the raw identifier
      _idtype, clean_identifier = identifier_type(id: primary_id)
      clean_identifier ||= identifier

      # A record is edited under the form that wrote it, whatever name the URL
      # used: a link from a search of the shared dbname (e.g. "project") would
      # otherwise open a page with the fields of EVERY form sharing it, and
      # saving that page would stamp the record with the dbname instead of its
      # real form (so it would drop out of that form's searches).
      #
      # The one exception is a record still on a user-facing form, which an
      # administrator may open under a Core form sharing its dbname to curate it
      # (see curation_targets): the URL then names that Core form on purpose,
      # and saving re-stamps the record with it.
      record_form = get_record_form(primary_id: clean_identifier)
      if record_form && record_form != database && !CBGP::Dataset.fields_for(record_form).empty?
        target = session[:role] == 'admin' ? curation_targets(record_form).find { |_label, form| form == database } : nil
        unless target
          redirect "/cbgp/dataset/#{ERB::Util.url_encode(record_form)}/#{ERB::Util.url_encode(clean_identifier)}"
        end

        @curating_from = record_form
        @curating_label = target.first
        @not_carried = values_not_carried(from_form: record_form, to_form: database, primary_id: clean_identifier)
      end
      @curation_targets = session[:role] == 'admin' && record_form == database ? curation_targets(record_form) : []

      @entry = CBGP::Dataset.load_from_primary_id(database: database, primary_id: clean_identifier)
      @related_panels = CBGP::RelatedRecords.panels_for(entry: @entry, type: @database) # ontology-declared; usually empty
      erb :dataset, layout: :database_layout
    end

    # Sets what the results page needs to say about the search itself:
    # @show_all (the "Show all records" request) and @no_terms (a form
    # submitted with every box empty - nothing was searched for).
    def note_search_kind(search_params) # rubocop:disable Lint/NestedMethodDefinition
      @show_all = show_all_requested?(search_params)
      @no_terms = !@show_all && search_terms_blank?(search_params)
      @today_date = search_uses_today?(search_params.to_h) ? Date.today.iso8601 : nil # said on the results page
    end

    # Loads @database/@fields/@datasets for the search this session last ran on
    # +database+, ready for the search_dataset_resultform view. Returns false
    # (and sets nothing) when there is no such search to repeat.
    def render_last_search_results(database:) # rubocop:disable Lint/NestedMethodDefinition
      last_search = session[:last_search]
      return false unless last_search && last_search[:database] == database

      @database = database
      @fields = search_fields_for(@database)
      note_search_kind(last_search[:params])
      graphuris = execute_search(search_params: last_search[:params], dataset_type: @database)
      @datasets = graphuris.map { |graphuri| CBGP::Dataset.load_from_graph(graph: graphuri, database: @database) }
      @result_warnings = CBGP::RelatedRecords.result_warnings(datasets: @datasets, type: @database)
      @record_forms = record_forms_for_results(graphuris: graphuris, datasets: @datasets)
      true
    end

    # primary_id => form class for the rows of a results page (the "Record
    # type" column); @datasets is in the same order as +graphuris+.
    def record_forms_for_results(graphuris:, datasets:) # rubocop:disable Lint/NestedMethodDefinition
      by_graph = batch_retrieve_record_forms(graph_uris: graphuris)
      graphuris.zip(datasets).each_with_object({}) do |(graph, dataset), forms|
        form = by_graph[graph.to_s]
        forms[dataset.primary_id] = form if form && dataset
      end
    end

    def delete_dataset(database:, primary_id:) # rubocop:disable Lint/NestedMethodDefinition
      halt 400, 'primary Identifier required' if primary_id.to_s.strip.empty?
      @database = database # needs to be shared

      # Perform the delete
      graphres = retrieve_dataset_graph_query(primary_id: primary_id)
      if graphres.empty?
        # Optional: flash error "Record not found"
        redirect '/cbgp/dashboard' # or search form
      end
      warn "Deleting #{graphres.inspect}"
      graphuri = graphres.first[:g].to_s
      warn "Deleting id #{graphres.inspect}"

      delete_dataset_query(oldid: graphuri)

      # Try to return to the previous search results
      if render_last_search_results(database: @database)
        flash[:notice] = 'Record deleted successfully.'
        halt erb(:search_dataset_resultform, layout: :database_layout)
      end

      # No search context - fall back to the dashboard
      redirect '/cbgp/dashboard'
    end
  end
end
