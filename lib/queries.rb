# frozen_string_literal: true

require 'linkeddata'
require 'sparql'
require 'sparql/client'
require 'securerandom'
require 'date'
require_relative 'virtuoso_update_client'
# require 'unicode' # If not already available; Ruby stdlib has String#unicode_normalize, but ensure it's loaded if needed

host = VIRTUOSO_HOST || 'localhost:8890'
history_host = VIRTUOSO_HISTORY_HOST || 'localhost:8891'

$ontology = RDF::Repository.load(CBGP_KB) # set in configuration.rb and/or in docker-compose

# Reads: plain SPARQL::Client against Virtuoso's /sparql endpoint - Virtuoso
# allows anonymous SELECT/CONSTRUCT there by default (same as GraphDB's
# /repositories/<name> did, just without needing credentials in the URL).
#
# The explicit default Accept header is required, not decorative - confirmed
# live 2026-08-26: on a persistent (keep-alive) connection that has already
# handled a mix of query types, Virtuoso's own default content negotiation
# for a follow-up SELECT can drift to something sparql-client's SELECT
# parser doesn't expect (observed: an RDF::ReaderError trying to parse a
# results document as NTriples), and separately a CONSTRUCT can come back
# as SELECT-shaped JSON bindings instead of a graph - see the CONSTRUCT call
# sites in this file/history_queries.rb, which is why they override this
# default with content_type: 'application/n-triples' per call. GraphDB never
# needed any of this; its content negotiation was stable across a
# connection's whole request history.
DATABASE = CBGP::SparqlClient.new("http://#{host}/sparql", headers: { 'Accept' => 'application/sparql-results+json' })
# Writes: Virtuoso's /sparql-auth requires HTTP Digest auth and rejects Basic
# outright - confirmed live against a real Virtuoso 07.20 container, no
# virtuoso.ini setting in that build offers a way around it - hence the
# dedicated client in lib/virtuoso_update_client.rb instead of SPARQL::Client
# (which has no Digest support).
DATABASE_UPDATE = CBGP::VirtuosoUpdateClient.new(endpoint: "http://#{host}/sparql-auth", user: VIRTUOSO_USER, password: VIRTUOSO_PASS)

# SCD Type 2 history store — a separate Virtuoso container/process (not a
# namespaced graph in DATABASE) that holds snapshots of superseded/deleted
# records. See delete_dataset_query.
HISTORY_DATABASE = CBGP::SparqlClient.new("http://#{history_host}/sparql", headers: { 'Accept' => 'application/sparql-results+json' })
HISTORY_DATABASE_UPDATE = CBGP::VirtuosoUpdateClient.new(endpoint: "http://#{history_host}/sparql-auth", user: HISTORY_USER, password: HISTORY_PASS)

PREFIXES = "PREFIX cbgp: <https://w3id.org/CBGP-App#>
PREFIX owl: <http://www.w3.org/2002/07/owl#>
PREFIX rdf: <http://www.w3.org/1999/02/22-rdf-syntax-ns#>
PREFIX xml:<http://www.w3.org/XML/1998/namespace>
PREFIX xsd:<http://www.w3.org/2001/XMLSchema#>
PREFIX rdfs:<http://www.w3.org/2000/01/rdf-schema#>
PREFIX sio: <http://semanticscience.org/resource/>
PREFIX schema: <http://schema.org/>
PREFIX edam: <http://edamontology.org/>
PREFIX obo: <http://purl.obolibrary.org/obo/>
PREFIX ncit: <http://purl.obolibrary.org/obo/>
PREFIX local: <urn:local:>
PREFIX dcterms: <http://purl.org/dc/terms/>   # NEW: for provenance timestamps
"

# what database should we be writing to or reading from?
def get_dbname_for_form(form:) # form is e.g. publication or userproject
  form = validate_local_name!(form, field: 'form')
  # questionnaire_type = Add/Edit publications (#publication) has-fields Publication Questions (#new-publication-questions)
  classname = "cbgp:#{form}"
  qs = <<GET_DBNAME
    #{PREFIXES}

    SELECT ?dbname WHERE {
      #{classname} rdfs:subClassOf cbgp:forms ;
        local:dbname ?dbname .  # this is just the string, like "project"
    }
GET_DBNAME
  warn "database name query\n\n#{qs}\n\n" if ENV['CBGP_DEBUG_SPARQL']
  qs = SPARQL.parse(qs)
  results = qs.execute($ontology)
  results.first[:dbname].to_s
end

# The category a form is listed under (local:form-category: "Core" for the
# forms the Add and Query lists are built from, "UserFacing" for the
# cut-down forms users fill in themselves), or nil if it has none / is no form.
def form_category_for(form)
  form = validate_local_name!(form, field: 'form')
  row = SPARQL.parse(<<~SPARQL).execute($ontology).first
    #{PREFIXES}
    SELECT ?category WHERE { cbgp:#{form} rdfs:subClassOf cbgp:forms ; local:form-category ?category }
  SPARQL
  row && row.bound?(:category) ? row[:category].to_s : nil
rescue ArgumentError
  nil
end

# The forms of +category+ (default "Core", the ones the Query and Add lists
# are built from - see get_questionnaire_types_query) stored under +dbname+;
# several forms can share one. Empty for a name that is no such form's dbname.
# Forms of another category (e.g. the cut-down user-facing ones) are left out
# on purpose: they are not offered as search scopes, and counting their
# smaller field lists would shrink what a search across the rest can offer.
def forms_sharing_dbname(dbname:, category: 'Core')
  dbname = validate_local_name!(dbname, field: 'dbname')
  category = validate_local_name!(category, field: 'category')
  SPARQL.parse(<<~SPARQL).execute($ontology).map { |row| row[:form].to_s.split('#').last }.uniq.sort
    #{PREFIXES}
    SELECT ?form WHERE {
      ?form rdfs:subClassOf cbgp:forms ;
            local:dbname ?dbname ;
            local:form-category ?category .
      FILTER (str(?dbname) = "#{dbname}" && str(?category) = "#{category}")
    }
  SPARQL
end

# Resolves a search scope given as either a form class or a storage dbname
# into [dbname to look under, form to restrict to (nil = every form on it)].
# Records are stored under the form's shared dbname (see storage_dbname_for);
# searching a FORM must therefore look under its dbname and keep only the
# records that form wrote - identified by the dcterms:type stamp every record
# carries - while searching the dbname itself covers all forms sharing it
# (what cross-reference lookups want).
def search_scope_for(type)
  dbname = storage_dbname_for(type)
  [dbname, dbname == type ? nil : type]
end

# The triple pattern that keeps only records stamped as written by +form+.
# The stamp is graph metadata (default graph, subject = the record's graph
# URI), so this sits outside the GRAPH block it constrains.
def form_scope_pattern(form)
  form ? "?datasetgraph dcterms:type cbgp:#{validate_local_name!(form, field: 'form')} ." : ''
end

# The storage dbname a record of +type+ is written under: for a form class,
# its local:dbname (several forms can share one - e.g. all the project forms
# store under "project"); for anything else (already a dbname, or unknown),
# +type+ itself. Never raises - a write must not fail just because the type
# turned out to be a dbname rather than a form.
def storage_dbname_for(type)
  dbname = get_dbname_for_form(form: type)
  dbname.to_s.strip.empty? ? type : dbname
rescue StandardError
  type
end

def get_questionnaire_types_query(type: 'Core', language: current_language) # rubocop:disable Metrics/MethodLength
  type = validate_local_name!(type, field: 'type')
  language = validate_local_name!(language, field: 'language')
  # questionnaire_type = Add/Edit publications (#publication) has-fields Publication Questions (#new-publication-questions)

  qs = <<GET_QUESTIONNAIRE_TYPES
    #{PREFIXES}

    SELECT ?questionnaire_type ?questionnaire_label WHERE {
      ?questionnaire_type rdfs:subClassOf cbgp:forms .
      ?questionnaire_type rdfs:label ?questionnaire_label .
      ?questionnaire_type local:form-category ?category .  # is this part of the core database or the user-facing forms
      # Compared as plain text, ignoring any language tag: a category written without @en
      # (as the European and Private project forms were) silently dropped the form from
      # every menu when this matched "Core"@en exactly.
      FILTER (str(?category) = "#{type}")
      FILTER (lang(?questionnaire_label) = "#{language}")
    }
GET_QUESTIONNAIRE_TYPES
  qs = SPARQL.parse(qs)
  results = qs.execute($ontology)
  results.map { |r| r.to_h.transform_values(&:to_s) } # https://w3id.org/CBGP-App#add-member => "Add/Edit Member"
end

def get_questionnaire_sections_query(questionnaire_type:, language: current_language)
  return [] unless questionnaire_type

  questionnaire_type = validate_local_name!(questionnaire_type, field: 'questionnaire_type')
  language = validate_local_name!(language, field: 'language')

  warn "\n\nIn get_questionnaire_sections with #{questionnaire_type} and #{language}\n\n\n"

  # questionnaire_type = Add/Edit publications (#add-publication) has-fields Publication Questions (#new-publication-questions)

  qs = <<GET_QUESTIONNAIRE_SECTIONS
    #{PREFIXES}

    SELECT ?sec (str(?seclab) as ?label) WHERE {
      cbgp:#{questionnaire_type} local:has-fields ?sec . # "publication", "project", "member"
      ?sec rdfs:label ?seclab .
      FILTER (lang(?seclab) = "#{language}")
    }
GET_QUESTIONNAIRE_SECTIONS
  warn "QUERY IS #{qs} on ontology #{$ontology} #{$ontology.size}" if ENV['CBGP_DEBUG_SPARQL']
  qs = SPARQL.parse(qs)
  result = qs.execute($ontology)
  warn "questionnaire_sections_query result: #{result.inspect}" if ENV['CBGP_DEBUG_SPARQL']
  return result unless result.empty?

  get_dbname_sections_query(dbname: questionnaire_type, language: language)
end

# Fallback for get_questionnaire_sections_query when its argument isn't a
# form class at all but a shared storage dbname (e.g. "project", which
# several forms - european_research_project, personnel_project, ... - all
# store under, and which is itself NOT an ontology class since Sara's
# project-fields split). Returns the sections of every form sharing that
# dbname, so the dbname resolves to the union of those forms' fields -
# needed wherever the only thing known is the storage table, e.g. a
# cross-reference field whose local:references target is "project": the
# record found there could have been written by any of the project forms.
# Same row shape as get_questionnaire_sections_query (?sec, ?label); empty
# for a name that is neither a form nor a dbname.
def get_dbname_sections_query(dbname:, language:)
  dbname = validate_local_name!(dbname, field: 'dbname')
  language = validate_local_name!(language, field: 'language')

  qs = <<GET_DBNAME_SECTIONS
    #{PREFIXES}

    SELECT DISTINCT ?sec (str(?seclab) as ?label) WHERE {
      ?form rdfs:subClassOf cbgp:forms ;
            local:dbname ?dbname ;
            local:has-fields ?sec .
      FILTER (str(?dbname) = "#{dbname}")
      ?sec rdfs:label ?seclab .
      FILTER (lang(?seclab) = "#{language}")
    }
GET_DBNAME_SECTIONS
  SPARQL.parse(qs).execute($ontology)
end

def get_section_questions_query(sectionid:, language: current_language)
  sectionid = validate_local_name!(sectionid, field: 'sectionid')
  language = validate_local_name!(language, field: 'language')
  qs = <<GET_SECTION_QUESTIONS
    #{PREFIXES}

    SELECT ?q (str(?qlab) as ?label) ?widget ?class ?method ?cardinality ?answers ?primary ?sequence ?references ?references_via ?references_label (str(?qcomment) as ?comment) WHERE {
    ?q rdfs:subClassOf cbgp:#{sectionid} .
    ?q rdfs:label ?qlab .
    FILTER (lang(?qlab) = "#{language}")
    ?q local:widget-type ?widget .
    ?q local:widget-cardinality ?cardinality .
    ?q local:answer-block ?answers .
    ?q local:method ?method .
    ?q local:question-order ?sequence .
    OPTIONAL {?q local:object-class ?class }.
    OPTIONAL {?q local:is-primary-id ?primary }.
    OPTIONAL { ?q local:references ?references . }
    OPTIONAL { ?q local:references-via ?references_via . }
    OPTIONAL { ?q local:references-label ?references_label . }
    OPTIONAL { ?q rdfs:comment ?qcomment . FILTER (lang(?qcomment) = "#{language}") }
  } ORDER BY ?sequence

GET_SECTION_QUESTIONS
  qs = SPARQL.parse(qs)
  qs.execute($ontology)
end

# Fetches a form's pre-populated defaults: the local:has-defaults branch lets
# a form assign a default answer to one of its fields *without* that default
# living on the shared question class itself — necessary because the same
# question class can be reused across multiple forms (e.g. a field shared by
# both Research and Personnel projects), each of which may want a different
# default, or none at all.
#
#   cbgp:personnel_project local:has-defaults cbgp:some_default_node .
#   cbgp:some_default_node local:default-for-field cbgp:project_x ;
#                           local:default-value    "some value" .
#
# @param form_class [String] the specific form class fragment, e.g.
#   "personnel_project" - NOT the shared dbname ("project")
# @return [SPARQL::Client::Solutions] rows with ?field (full URI) and ?value
def get_form_defaults_query(form_class:)
  form_class = validate_local_name!(form_class, field: 'form_class')
  qs = <<~GET_FORM_DEFAULTS
    #{PREFIXES}
    SELECT ?field ?value WHERE {
      cbgp:#{form_class} local:has-defaults ?d .
      ?d local:default-for-field ?field ;
         local:default-value ?value .
    }
  GET_FORM_DEFAULTS
  qs = SPARQL.parse(qs)
  qs.execute($ontology)
end

# Fetches which of a FORM's fields are mandatory, per local:requires-field
# (see the AnnotationProperty declaration in the .owl file for the full
# rationale — short version: unlike local:has-defaults, "required" carries
# no extra data beyond "yes, this field", so it's a single direct property
# straight from the form to the question class, not a two-piece reified
# node like a default is).
#
# This is a SIBLING query to get_form_defaults_query above, not a variant of
# it — deliberately kept as its own small, single-purpose SPARQL string
# (rather than, say, cramming an extra OPTIONAL onto some other query)
# because it answers a genuinely different question: "does this exist for
# this form?" rather than "what value does this have for this form?".
#
#   cbgp:personnel_project local:requires-field cbgp:project_annual_income .
#
# @param form_class [String] the specific form class fragment, e.g.
#   "personnel_project" — the same "must be the real form, not the shared
#   dbname" caveat as get_form_defaults_query applies here too: this has to
#   be called with the actual form (e.g. "personnel_project"), never with
#   the dbname ("project"), or every form sharing that dbname would appear
#   to require the same fields.
# @return [SPARQL::Client::Solutions] rows with a single ?field (full URI)
#   binding per required field — there is no "value" column here, only
#   presence/absence of a row for a given field
def get_form_required_fields_query(form_class:)
  form_class = validate_local_name!(form_class, field: 'form_class')
  qs = <<~GET_FORM_REQUIRED_FIELDS
    #{PREFIXES}
    SELECT ?field WHERE {
      cbgp:#{form_class} local:requires-field ?field .
    }
  GET_FORM_REQUIRED_FIELDS
  qs = SPARQL.parse(qs)
  qs.execute($ontology)
end

# Fetches a form's calculated-field formulas: the local:has-formulas branch,
# a THIRD sibling of has-defaults/requires-field above (see the
# local:has-formulas AnnotationProperty comment in the .owl file for the
# full rationale). Shaped exactly like get_form_defaults_query — a formula
# is TWO pieces of data per (form, field) (which field, AND the formula
# text), so it needs the same reified intermediate-node shape as a default
# does, not the direct-property shape "required" uses.
#
#   cbgp:project local:has-formulas cbgp:some_formula_node .
#   cbgp:some_formula_node local:formula-for-field  cbgp:project_cbgp_overheads ;
#                           local:formula-expression "project_total_funding * 0.13" .
#
# @param form_class [String] the specific form class fragment, e.g.
#   "project" - same caveat as its siblings: must be the real form class,
#   never the shared dbname.
# @return [SPARQL::Client::Solutions] rows with ?field (full URI) and
#   ?formula (the Dentaku expression string) per calculated field this form
#   declares
def get_form_formulas_query(form_class:)
  form_class = validate_local_name!(form_class, field: 'form_class')
  qs = <<~GET_FORM_FORMULAS
    #{PREFIXES}
    SELECT ?field ?formula WHERE {
      cbgp:#{form_class} local:has-formulas ?f .
      ?f local:formula-for-field  ?field ;
         local:formula-expression ?formula .
    }
  GET_FORM_FORMULAS
  qs = SPARQL.parse(qs)
  qs.execute($ontology)
end

# Fetches a form's CONDITIONAL requirements: local:has-conditional-requirements,
# a sibling of requires-field above for a field that is required only when
# ANOTHER field has a particular answer (e.g. dates only once a project is
# Awarded). Reified like a default or formula, since a rule is several pieces
# of data:
#
#   cbgp:some_form local:has-conditional-requirements cbgp:some_rule .
#   cbgp:some_rule local:conditional-requirement-field       cbgp:project_end_date ;
#                  local:conditional-requirement-when-field  cbgp:project_status ;
#                  local:conditional-requirement-when-answer cbgp:Awarded .
#
# (when-answer may repeat: "required when the answer is any of these".)
#
# @param form_class [String] the specific form class
# @return [RDF::Query::Solutions] rows with ?field, ?when_field, ?answer
def get_form_conditional_requirements_query(form_class:)
  form_class = validate_local_name!(form_class, field: 'form_class')
  qs = <<~GET_FORM_CONDITIONAL_REQUIREMENTS
    #{PREFIXES}
    SELECT ?field ?when_field ?answer WHERE {
      cbgp:#{form_class} local:has-conditional-requirements ?r .
      ?r local:conditional-requirement-field       ?field ;
         local:conditional-requirement-when-field  ?when_field ;
         local:conditional-requirement-when-answer ?answer .
    }
  GET_FORM_CONDITIONAL_REQUIREMENTS
  qs = SPARQL.parse(qs)
  qs.execute($ontology)
end

# The fields that accompany +questionclass+ whenever it is used as the label
# of a cross-reference: local:label-companion. A person's surname alone does
# not tell two people apart, so the ontology can say that wherever
# member_surnames is shown as a label the member's name comes with it:
#
#   cbgp:member_surnames local:label-companion cbgp:member_name .
#
# @param questionclass [String]
# @return [RDF::Query::Solutions] rows with ?companion
def get_label_companions_query(questionclass:)
  questionclass = validate_local_name!(questionclass, field: 'questionclass')
  qs = <<~GET_LABEL_COMPANIONS
    #{PREFIXES}
    SELECT ?companion WHERE {
      cbgp:#{questionclass} local:label-companion ?companion .
    }
  GET_LABEL_COMPANIONS
  SPARQL.parse(qs).execute($ontology)
end

# Fetches an ANSWER's trigger declarations: local:has-triggers, a fourth
# sibling of has-defaults/has-formulas/requires-field. Unlike those three,
# this is keyed by the ANSWER class, not the form class - a trigger is a
# property of the answer itself ("selecting Yes here means X should
# happen"), true on every form that happens to ask the question, not just
# one. See get_form_triggers_query below for the form-level sibling (fires
# on record creation rather than on a specific answer being selected) -
# same reified-node shape, same trigger-type/trigger-recipient-key
# properties, just a different subject.
#
#   cbgp:member_approved_yes local:has-triggers cbgp:member_approved_yes_photo_trigger .
#   cbgp:member_approved_yes_photo_trigger
#       local:trigger-type            "email" ;
#       local:trigger-recipient-key   "photo_id_scheduler" .
#
# Only a symbolic recipient KEY ever lives here - never a literal email
# address. The ontology is synced publicly (w3id.org/GitHub Pages), so real
# addresses resolve from TRIGGER_RECIPIENTS (app config) by this key at
# dispatch time instead - see lib/triggers.rb.
#
# @param answer_class [String] the specific Answer class fragment, e.g.
#   "member_approved_yes"
# @return [SPARQL::Client::Solutions] rows with ?type and (optionally)
#   ?recipient_key per trigger this answer declares
def get_answer_triggers_query(answer_class:)
  answer_class = validate_local_name!(answer_class, field: 'answer_class')
  qs = <<~GET_ANSWER_TRIGGERS
    #{PREFIXES}
    SELECT ?type ?recipient_key WHERE {
      cbgp:#{answer_class} local:has-triggers ?t .
      ?t local:trigger-type ?type .
      OPTIONAL { ?t local:trigger-recipient-key ?recipient_key }
    }
  GET_ANSWER_TRIGGERS
  qs = SPARQL.parse(qs)
  qs.execute($ontology)
end

# Form-level sibling of get_answer_triggers_query above: local:has-triggers
# on the FORM class itself means "fires when a record of this form is
# newly created" (checked by CBGP::Triggers.check_and_fire only when
# dataset.old_values is nil, i.e. this save was a creation, not an edit) -
# the same generic mechanism that replaces the old hardcoded
# notify_new_user_submission call, see lib/triggers.rb.
#
# @param form_class [String] the specific form class fragment, e.g. "member"
#   - same caveat as get_form_formulas_query: must be the real form class,
#   never the shared dbname.
# @return [SPARQL::Client::Solutions] rows with ?type and (optionally)
#   ?recipient_key per trigger this form declares
def get_form_triggers_query(form_class:)
  form_class = validate_local_name!(form_class, field: 'form_class')
  qs = <<~GET_FORM_TRIGGERS
    #{PREFIXES}
    SELECT ?type ?recipient_key WHERE {
      cbgp:#{form_class} local:has-triggers ?t .
      ?t local:trigger-type ?type .
      OPTIONAL { ?t local:trigger-recipient-key ?recipient_key }
    }
  GET_FORM_TRIGGERS
  qs = SPARQL.parse(qs)
  qs.execute($ontology)
end

# Fetches the related-records panels a form (or every form sharing a
# dbname) declares: local:has-related-records, a sibling of
# has-defaults/has-formulas/has-triggers. A panel lists the records of
# ANOTHER form that point back at the one being viewed - see the
# related-records-definition class comment in the ontology for the
# vocabulary, and lib/related_records.rb for how it is rendered.
#
#   cbgp:member local:has-related-records cbgp:member_commitments_panel .
#   cbgp:member_commitments_panel
#       local:related-form       cbgp:funding_commitment ;
#       local:related-via        cbgp:commitment_member ;
#       local:related-sum-field  cbgp:commitment_percentage ;
#       local:related-expected-total 100 ; ...
#
# @param type [String] a form class fragment, or a shared dbname (resolved
#   to the union of the panels of every form sharing it, same fallback as
#   get_questionnaire_sections_query)
# @return [SPARQL::Client::Solutions] one row per panel: ?panel, ?title,
#   ?related_form (+ its label as ?related_form_label), ?via and, where declared, ?key_field, ?sum_field, ?from_field,
#   ?to_field, ?expected_total, ?tolerance
def get_related_records_panels_query(type:, language: current_language)
  type = validate_local_name!(type, field: 'type')
  language = validate_local_name!(language, field: 'language')
  qs = <<~GET_RELATED_PANELS
    #{PREFIXES}
    SELECT DISTINCT ?panel (str(?label) as ?title) ?related_form (str(?form_label) as ?related_form_label) ?via ?key_field ?sum_field ?from_field ?to_field ?expected_total ?tolerance WHERE {
      {
        cbgp:#{type} local:has-related-records ?panel .
      } UNION {
        ?form rdfs:subClassOf cbgp:forms ;
              local:dbname ?dbname ;
              local:has-related-records ?panel .
        FILTER (str(?dbname) = "#{type}")
      }
      ?panel rdfs:label ?label .
      FILTER (lang(?label) = "#{language}")
      ?panel local:related-form ?related_form ;
             local:related-via ?via .
      OPTIONAL { ?related_form rdfs:label ?form_label . FILTER (lang(?form_label) = "#{language}") }
      OPTIONAL { ?panel local:related-key-field ?key_field }
      OPTIONAL { ?panel local:related-sum-field ?sum_field }
      OPTIONAL { ?panel local:related-active-from-field ?from_field }
      OPTIONAL { ?panel local:related-active-to-field ?to_field }
      OPTIONAL { ?panel local:related-expected-total ?expected_total }
      OPTIONAL { ?panel local:related-tolerance ?tolerance }
    }
  GET_RELATED_PANELS
  SPARQL.parse(qs).execute($ontology)
end

# The columns (question classes of the related form) a related-records panel
# lists. Order is NOT taken from here - the caller sorts by the related
# form's own question-order, so the panel always reads like the form itself.
#
# @param panel [String] panel node fragment, e.g. "member_commitments_panel"
# @return [SPARQL::Client::Solutions] rows with ?column (full URI)
def get_related_records_columns_query(panel:)
  panel = validate_local_name!(panel, field: 'panel')
  qs = <<~GET_RELATED_COLUMNS
    #{PREFIXES}
    SELECT ?column WHERE {
      cbgp:#{panel} local:related-column ?column .
    }
  GET_RELATED_COLUMNS
  SPARQL.parse(qs).execute($ontology)
end

def get_answer_block_query(ablockid:, language: current_language)
  ablockid = validate_local_name!(ablockid, field: 'ablockid')
  language = validate_local_name!(language, field: 'language')
  a = <<GET_ANSWER_BLOCK
    #{PREFIXES}

    SELECT DISTINCT ?aid ?label ?sequence WHERE {
      ?aid rdfs:subClassOf cbgp:#{ablockid} .
      ?aid rdfs:label ?label .
      FILTER (lang(?label) = "#{language}")
      ?aid local:answer-order ?sequence .
    } ORDER BY ?sequence
GET_ANSWER_BLOCK
  # warn "ANSWERBLOCK QUERY IS #{a}"

  a = SPARQL.parse(a)
  a.execute($ontology)
end

def get_hierarchical_answer_block_query(ablockid:, language: current_language)
  language = validate_local_name!(language, field: 'language')
  query = <<~GET_HIERARCHICAL_ANSWERS
    #{PREFIXES}
    SELECT DISTINCT ?aid ?label ?parent ?sequence WHERE {
      ?aid rdfs:subClassOf ?parent .
      ?aid rdfs:label ?label .
      FILTER (lang(?label) = "#{language}")
      OPTIONAL { ?aid local:answer-order ?sequence . }
    } ORDER BY ?sequence
  GET_HIERARCHICAL_ANSWERS

  # warn "HIERARCHICAL ANSWERBLOCK QUERY IS #{query}"
  results = SPARQL.parse(query).execute($ontology)
  tree = build_transitive_tree(results, abblockid: ablockid)
  JSON.generate(tree) # Use JSON.generate for explicit control
end

def get_label_for_questionnaire_type(id:, language: current_language)
  id = validate_local_name!(id, field: 'id')
  language = validate_local_name!(language, field: 'language')
  lab = SPARQL.parse("
    #{PREFIXES}

    SELECT ?plabel ?label WHERE {
      cbgp:#{id} rdfs:label ?label ;
                 rdfs:subClassOf ?parent .
      ?parent rdfs:label ?plabel
      FILTER (lang(?label) = '#{language}')
      FILTER (lang(?plabel) = '#{language}')
    }
          ")

  res = lab.execute($ontology)
  [res.first[:plabel].to_s, res.first[:label].to_s]
end

def get_label_for_id(id:, language: current_language)
  return nil if id.nil? || id.empty?

  # Strip the document fragment from the URI if it includes a '#'
  id = id.to_s.split('#').last if id.to_s.include?('#')
  id = validate_local_name!(id, field: 'id')
  language = validate_local_name!(language, field: 'language')

  query = <<~LABEL_QUERY
    #{PREFIXES}
    SELECT ?label WHERE {
    cbgp:#{id} rdfs:label ?label .
    FILTER (lang(?label) = '#{language}')
    }
    LIMIT 1
  LABEL_QUERY

  warn "LABEL QUERY FOR #{id}: #{query}" if ENV['CBGP_DEBUG_SPARQL']
  res = SPARQL.parse(query).execute($ontology)
  if res.any? && res.first&.bound?(:label)
    res.first[:label].to_s
  else
    warn "No label found for id: #{id}"
    id # Fallback to id
  end
end

def field_query(fieldid:, language: current_language)
  fieldid = validate_local_name!(fieldid, field: 'fieldid')
  language = validate_local_name!(language, field: 'language')
  query = <<~FIELDQ
    #{PREFIXES}
    SELECT ?label ?answerblock ?objectclass ?objectmethod ?questionorder ?cardinality ?widgettype
    WHERE {
        cbgp:#{fieldid} rdfs:label ?label ;
          local:answer-block ?answerblock ;
          local:method ?objectmethod ;
          local:question-order ?questionorder ;
          local:widget-cardinality ?cardinality ;
          local:widget-type ?widgettype .
        FILTER (lang(?label) = '#{language}')
        OPTIONAL {cbgp:#{fieldid} local:object-class ?objectclass .}
    }
  FIELDQ
  # warn "FIELD QUERY is #{query}"
  field = SPARQL.parse(query)
  field.execute($ontology)
end

##############################################################################
# Dataset persistence — SPARQL queries for reading, writing, and deleting
# records stored as named graphs.
#
# Each record lives in its own named graph whose URI follows the pattern:
#   #{BASE_URI}<form_type>/context/<primary_id>
#
# Inside the graph, fields are encoded using the SIO reified-attribute pattern:
#   <dataset_node> sio:SIO_000008 <attribute_node> .
#   <attribute_node> rdf:type cbgp:<questionclass> ;
#                    sio:SIO_000300 "<literal_value>" .
#
# Provenance triples (dcterms:created / dcterms:modified / dcterms:type) are
# written INSIDE each record's own named graph, subject = the graph's own
# URI. Every reader already knows the specific graph URI in advance (there is
# no cross-graph "find by dcterms:type" query anywhere in this codebase), so
# nothing needs them to live outside it - and putting them outside doesn't
# actually work on Virtuoso: its INSERT DATA implementation requires an
# explicit default-graph preamble for any triple not wrapped in its own
# GRAPH {} block, which SPARQL 1.1 doesn't provide a way to supply for
# INSERT DATA specifically (confirmed live, 2026-08-26, migrating personnel
# data - GraphDB tolerated the old default-graph placement, Virtuoso
# rejects it outright: "Virtuoso 37000 Error SP031: ... No plain default
# graph specified in the preamble"). delete_dataset_query no longer needs a
# separate DELETE WHERE for these triples either - DROP GRAPH now removes
# them along with everything else in the record's graph.
##############################################################################

# Finds the named graph URI that contains a record with the given primary_id.
# Searches across all graphs for a node whose sio:SIO_000115 (identifier) has
# the given string value.  Returns a SPARQL result set; the caller reads +[:g]+.
#
# @note Prone to collisions if two records share the same primary_id string
#   across different form types.  Scoping by graph prefix would eliminate this.
#
# @param primary_id [String] the record's primary identifier value
# @return [SPARQL::Client::Solutions] result rows with +?g+ bound to the graph URI
# The form class (e.g. "personnel_project") that wrote the record with this
# primary id, read from the dcterms:type stamp every record carries - or nil
# if it has none (an old record), cannot be found, or the store is not
# answering. Never raises: callers use it to pick the right edit page and
# must still be able to open a record when it cannot answer.
def get_record_form(primary_id:)
  graph = retrieve_dataset_graph_query(primary_id: primary_id).first
  return nil unless graph

  uri = RDF::URI(graph[:g].to_s)
  rows = DATABASE.query(<<~SPARQL).to_a
    #{PREFIXES}
    SELECT ?form WHERE { <#{uri}> dcterms:type ?form }
  SPARQL
  rows.first && rows.first[:form].to_s.split('#').last
rescue StandardError => e
  warn "[RECORD-FORM] could not read the form of #{primary_id.inspect}: #{e.class}: #{e.message}"
  nil
end

def retrieve_dataset_graph_query(primary_id:)
  retds = <<SELECT_DS
        #{PREFIXES}
  select ?g where {
  graph ?g {
      ?dataset sio:SIO_000671 ?id .

      ?id  sio:SIO_000300 "#{escape_for_literal(primary_id)}" ;
        rdf:type sio:SIO_000115 . # identifier
  }}

SELECT_DS

  warn "retrieve dataset graph query is:\n #{retds}" if ENV['CBGP_DEBUG_SPARQL']
  DATABASE.query(retds)
end

# Returns the primary_id string stored inside a known named graph.
# Useful when you have a graph URI (e.g. from a search result) and need to
# recover the human-facing identifier without loading the full record.
#
# @param graph [String] the full named graph URI
# @return [String, nil] the primary_id value, or +nil+ if the graph has none
def retrieve_dataset_id_from_graph_query(graph:)
  retds = <<SELECT_DS
        #{PREFIXES}
  select ?id where {
  graph <#{graph}> {
      ?dataset sio:SIO_000671 ?idnode .
      ?idnode  sio:SIO_000300 ?id ;
        rdf:type sio:SIO_000115 . # identifier
  }}
SELECT_DS

  warn "retrieve dataset id query is:\n #{retds}" if ENV['CBGP_DEBUG_SPARQL']
  results = DATABASE.query(retds)
  return results.first[:id].to_s if results

  nil
end

# Escapes a value for safe embedding in a SPARQL string literal.
#
# Must use the block form of gsub, not a string replacement: gsub
# re-interprets backslash sequences (\\, \1, \&, …) in a *string*
# replacement, so `gsub('\\', '\\\\')` — intended to double every backslash
# — is actually a no-op (the "doubled" replacement collapses back down to a
# single literal backslash on the way out). A block's return value is
# inserted literally, with no second interpretation pass, so this is safe.
#
# Also escapes literal newline/carriage-return/tab bytes to their ECHAR
# two-character sequences (\n, \r, \t) - the SPARQL grammar's short-quoted
# string literal ("...") forbids a raw LF/CR appearing inside it at all
# (Virtuoso: "End-of-line in a short double-quoted string"), not just quotes
# and backslashes. Found 2026-09-28 bulk-loading real personnel history data
# with genuine multi-line free-text fields (e.g. funding_comments) - every
# multi-line textarea submission through the ordinary admin/User forms was
# already exposed to this same crash, it just hadn't been hit by any
# existing spec or manual test before now.
#
# @param value [Object]
# @return [String]
def escape_for_literal(value)
  value.to_s.gsub(/["\\\n\r\t]/) do |c|
    case c
    when '"', '\\' then "\\#{c}"
    when "\n" then '\n'
    when "\r" then '\r'
    when "\t" then '\t'
    end
  end
end

# Validates a value that's about to be interpolated as a bare SPARQL
# identifier fragment (an ontology local name — e.g. cbgp:#{form},
# cbgp:#{questionclass}) rather than inside a quoted literal, so
# escape_for_literal doesn't apply: there's no quote to escape into, an
# unescaped value here can break out of the query's syntactic structure
# outright. Ontology local names are always simple ASCII identifiers (see
# local:method values throughout the .owl file), so anything else is
# rejected rather than guessed at. Previously every one of these was
# interpolated unchecked; harmless while callers only ever passed
# dropdown-derived values, not once these same call paths take arguments
# supplied by an LLM/agent (see the planned MCP query servers).
#
# The first character may be a digit, not just a letter/underscore: SPARQL/
# Turtle's own PN_LOCAL grammar explicitly permits it, and real ontology
# content actually uses it - e.g. cbgp:10C/cbgp:10D (member_code10's answer
# options). Found 2026-09-28 bulk-loading real personnel data: this
# rejected those two genuine, correctly-formed answer ids as invalid.
# Widening the allowed first-character set to the same safe charset already
# used for every other character introduces no new special characters, so
# this doesn't weaken the injection guard.
#
# @param value [Object] the value about to be interpolated
# @param field [String] name to reference in the error, e.g. "questionclass"
# @return [String] the validated value, unchanged
# @raise [ArgumentError] if value isn't a simple identifier
def validate_local_name!(value, field:)
  str = value.to_s
  raise ArgumentError, "Invalid #{field}: #{value.inspect}" unless str.match?(/\A[A-Za-z0-9_][\w-]*\z/)

  str
end

# "today" (any case) stands for the current date, so a saved search or link
# can mean "as of the day it is run". Anything else is returned unchanged for
# validate_date! to judge. The server's local date is used.
def resolve_date_keyword(value)
  value.to_s.strip.casecmp?('today') ? Date.today.iso8601 : value
end

# +search_params+ without its blank parts: empty strings, lists of blanks and
# ranges with both ends blank are dropped (the search form posts every box, filled
# or not). Blank parts never change a search, so what is left means exactly the
# same - and, as a query string, is short enough to bookmark.
def compact_search_params(search_params)
  case search_params
  when Hash
    search_params.each_with_object({}) do |(k, v), kept|
      c = compact_search_params(v)
      kept[k] = c unless c.nil?
    end.then { |h| h.empty? ? nil : h }
  when Array
    kept = search_params.map { |v| compact_search_params(v) }.compact
    kept.empty? ? nil : kept
  else
    search_params.to_s.strip.empty? ? nil : search_params
  end
end

# True when any value in +search_params+ (at any depth: a date range is a Hash)
# is the keyword "today", i.e. the search means something different tomorrow.
def search_uses_today?(search_params)
  case search_params
  when Hash then search_params.values.any? { |v| search_uses_today?(v) }
  when Array then search_params.any? { |v| search_uses_today?(v) }
  else search_params.to_s.strip.casecmp?('today')
  end
end

# Validates and normalizes a date string about to be interpolated into a
# SPARQL FILTER as a bare xsd:date literal (e.g.
# "#{start_date}"^^xsd:date) — same reasoning as validate_local_name!: this
# isn't a quoted-string context escape_for_literal handles, it's raw
# interpolation, and a crafted "start_date" could otherwise break out of
# the FILTER entirely. Round-trips through Date.parse so anything that
# isn't a real calendar date is rejected outright.
#
# @param value [String]
# @return [String] "YYYY-MM-DD"
# @raise [ArgumentError] if value isn't a parseable date
def validate_date!(value)
  str = value.to_s
  # Date.parse is deliberately lenient (it'll extract a date from the front
  # of a larger string and silently ignore the rest, e.g. trailing SPARQL
  # syntax) - useful for free-text input, wrong here. Anchor to exactly
  # YYYY-MM-DD first so there's nothing left over for an injected value to
  # smuggle through.
  raise ArgumentError, "Invalid date: #{value.inspect}" unless str.match?(/\A\d{4}-\d{2}-\d{2}\z/)

  Date.strptime(str, '%Y-%m-%d').iso8601
rescue ArgumentError, TypeError
  raise ArgumentError, "Invalid date: #{value.inspect}"
end

# The RDF datatype each field class is stored as, when it is not a plain
# string. Only dates are typed: SPARQL compares an xsd:string with an
# xsd:date silently wrongly (no error, wrong rows - Virtuoso answered
# "start <= today" with nothing), so a date has to be a real xsd:date in the
# store for any range search to be right. Extend here if another class ever
# needs a real datatype; nothing else in the app is tied to a specific field.
TYPED_LITERAL_DATATYPES = { 'date' => 'xsd:date' }.freeze

# The SPARQL literal for storing +value+ in a field of class +field_class+:
# a typed literal for the classes in TYPED_LITERAL_DATATYPES, otherwise a
# plain escaped string. A value that is not valid for its typed class is
# refused rather than quietly stored as text (which is exactly the silent
# failure typing exists to prevent).
#
# @param value [Object] already-coerced field value
# @param field_class [String, nil] the field's declared class (lowercased
#   here, so 'Date' works)
# @return [String] e.g. "\"2026-01-31\"^^xsd:date" or "\"text\""
# @raise [ArgumentError] if a typed class is given an invalid value
def sparql_literal(value, field_class)
  datatype = TYPED_LITERAL_DATATYPES[field_class.to_s.downcase]
  return "\"#{escape_for_literal(value)}\"" unless datatype

  "\"#{validate_date!(value.to_s.strip)}\"^^#{datatype}"
end

# Validates a value that's about to be interpolated as a bare IRI inside
# angle brackets (<#{value}>) — a different context from a quoted literal
# (escape_for_literal) or an ontology local name (validate_local_name!).
# primary_ids routinely contain characters a local name can't (an ORCID
# starts with a digit, a DOI contains slashes), so rather than allowlist a
# narrow shape, this only rejects the specific characters SPARQL's own
# IRIREF grammar forbids (<>"{}|^`\ plus control/whitespace characters) —
# exactly the characters that could break out of the <...> syntax.
#
# @param value [Object]
# @param field [String]
# @return [String]
# @raise [ArgumentError]
def validate_iri_component!(value, field:)
  str = value.to_s
  raise ArgumentError, "Invalid #{field}: #{value.inspect}" if str.match?(/[<>"{}|^`\\\x00-\x20]/)

  str
end

# Removes a named graph from the CURRENT-state repository (DATABASE), first
# snapshotting its prior state into the separate HISTORY repository
# (HISTORY_DATABASE/HISTORY_DATABASE_UPDATE) — this is the SCD Type 2
# recording mechanism. Called for both true deletes (reason: 'deleted', the
# default — single/multi-select delete, utilities/purge_dataset.rb) and, from
# write_dataset_to_db_query, edits (reason: 'superseded').
#
# Steps:
#   1. Read the live graph's own dcterms:created/dcterms:modified (inside the
#      graph itself, subject = graph URI) before touching anything.
#      dcterms:modified becomes the snapshot's prov:generatedAtTime (when
#      *this* version became current); dcterms:created is returned so the
#      caller can preserve it into the new write instead of losing it.
#   2. CONSTRUCT the old graph's triples out of DATABASE (read-only) and
#      INSERT them verbatim into a freshly-named graph in HISTORY_DATABASE,
#      then annotate that SAME snapshot graph (subject = the snapshot's own
#      URI, not a resource inside it — deliberately nanopub/PROV-style, not
#      mixed into the assertion data) with prov:generatedAtTime/
#      prov:invalidatedAtTime/local:history-reason/local:history-detail.
#      Two independent repositories are used — no SPARQL federation, no
#      INSERT-WHERE across connections.
#   3. Only then remove the live graph from DATABASE via DROP GRAPH, which
#      takes its provenance triples with it since they live inside it —
#      unchanged from the original delete logic in spirit, simpler in
#      practice (no separate cleanup step needed for triples that used to
#      live outside the graph).
#
# @param oldid [String] the full named graph URI to delete (in DATABASE)
# @param reason ['deleted', 'superseded'] why this version is ending
# @param detail [String, nil] heuristic human-readable summary of what
#   changed (see CBGP::Dataset... summarize_field_changes in lib/core.rb);
#   defaults to "Record deleted" when reason is 'deleted' and none is given
# @return [Hash] +{ created:, history_graph: }+ — +created+ is the prior
#   dcterms:created value (or nil for a brand-new record), for the caller to
#   preserve; +history_graph+ is the new snapshot's graph URI
def delete_dataset_query(oldid:, reason: 'deleted', detail: nil)
  detail ||= 'Record deleted' if reason == 'deleted'
  form_type, primary_id = oldid.match(%r{\A#{Regexp.escape(BASE_URI)}(.+)/context/(.+)\z})&.captures

  prov_results = DATABASE.query(<<~PROV)
    #{PREFIXES}
    SELECT ?created ?modified WHERE {
      GRAPH <#{oldid}> {
        OPTIONAL { <#{oldid}> dcterms:created  ?created }
        OPTIONAL { <#{oldid}> dcterms:modified ?modified }
      }
    }
  PROV
  created = prov_results.first&.bound?(:created) ? prov_results.first[:created].to_s : nil
  # Microsecond precision (iso8601(6)), not the bare/second-precision default:
  # full_timeline sorts snapshots by this string, and a bulk load (or any
  # rapid-succession edits within the same wall-clock second) would
  # otherwise produce identical timestamps for multiple versions of the same
  # record, making their relative order in the History DB arbitrary rather
  # than reflecting the order they were actually written in. Found
  # 2026-09-28 bulk-loading real personnel history data - several versions
  # per person landed in the same second.
  generated_at = prov_results.first&.bound?(:modified) ? prov_results.first[:modified].to_s : Time.now.utc.iso8601(6)

  history_graph = "#{BASE_URI}#{form_type}/history/#{primary_id}/#{SecureRandom.uuid}"
  now = Time.now.utc.iso8601(6)

  # An explicit Accept header is required here, not optional - confirmed
  # live 2026-08-26: without it, a CONSTRUCT on this connection can come
  # back as SELECT-shaped application/sparql-results+json bindings instead
  # of an RDF graph serialization, which sparql-client then can't parse as
  # RDF::Statements at all. GraphDB never had this problem.
  #
  # Passed as headers: (a FRESH hash), not content_type: - sparql-client's
  # Client#response does `headers = options[:headers] || @headers` with NO
  # dup, so content_type: silently overwrites DATABASE's own @headers in
  # place and leaks into every later call on this same client (a real
  # sparql-client bug, not a Virtuoso quirk - it broke the very next SELECT
  # in this same method's caller once discovered). A fresh hash here can't
  # touch @headers.
  old_triples = DATABASE.query(<<~CONSTRUCT, headers: { 'Accept' => 'application/n-triples' })
    #{PREFIXES}
    CONSTRUCT { ?s ?p ?o } WHERE { GRAPH <#{oldid}> { ?s ?p ?o } }
  CONSTRUCT
  HISTORY_DATABASE_UPDATE.insert_data(old_triples, graph: history_graph)

  # Metadata about the snapshot lives inside the snapshot's OWN graph
  # (alongside the copied triples inserted just above), not the default
  # graph - see write_dataset_to_db_query's doc comment for why not the
  # default graph in general; history snapshots are never dropped, so there
  # was never a reason for this metadata to live outside its own graph in
  # the first place.
  HISTORY_DATABASE_UPDATE.update(<<~META)
    #{PREFIXES}
    PREFIX prov: <http://www.w3.org/ns/prov#>
    INSERT DATA {
      GRAPH <#{history_graph}> {
        <#{history_graph}> prov:generatedAtTime    "#{generated_at}"^^xsd:dateTime ;
                            prov:invalidatedAtTime  "#{now}"^^xsd:dateTime ;
                            local:history-reason    "#{escape_for_literal(reason)}" ;
                            local:history-detail    "#{escape_for_literal(detail)}" .
      }
    }
  META

  # No separate DELETE WHERE needed for the provenance triples anymore -
  # they live inside <oldid> now, so DROP GRAPH removes them along with
  # everything else.
  #
  # SILENT is required on Virtuoso, not optional - confirmed live
  # 2026-08-26: Virtuoso tracks "graphs" as first-class entities separate
  # from "any graph URI that happens to have triples", and a graph that was
  # only ever populated via INSERT DATA (never an explicit CREATE GRAPH,
  # which this codebase has never done) doesn't count as one to Virtuoso's
  # DROP - plain DROP GRAPH raises "has not been explicitly created before"
  # even though the triples are really there and really get removed by
  # SILENT. GraphDB never distinguished the two.
  DATABASE_UPDATE.update(<<~DELETE_DATASET)
    #{PREFIXES}
    DROP SILENT GRAPH <#{oldid}>
  DELETE_DATASET

  { created: created, history_graph: history_graph }
end

# Executes the SPARQL UPDATE that persists a dataset to the triple store.
# When +oldid+ is supplied the old graph is deleted first, so this method
# serves both INSERT (new record) and REPLACE (edit) semantics.
#
# @param dataset [CBGP::Dataset] the populated dataset object to write
# @param oldid [String, nil] primary_id of the graph to delete before writing;
#   pass the same value as +dataset.primary_id+ to replace an existing record
#   while preserving its URI
# @return [Object] raw response from the SPARQL update endpoint
def write_dataset_to_db(dataset:, oldid: nil, form: nil)
  built = write_dataset_to_db_query(dataset: dataset, oldid: oldid, form: form)
  warn "WRITE DATASET QUERY\n#{built[:query]}\n\n\n" if ENV['CBGP_DEBUG_SPARQL']
  resp = DATABASE_UPDATE.update(built[:query])
  warn "write dataset response #{resp.inspect}" if ENV['CBGP_DEBUG_SPARQL']
  { resp: resp, old_values: built[:old_values] }
end

# Builds the SPARQL UPDATE string that inserts a dataset's triples.
#
# If +oldid+ is given, the old graph is first snapshotted into the SCD Type 2
# history repository and dropped (see +delete_dataset_query+, reason:
# 'superseded'), then an INSERT DATA block is constructed containing:
#   - Core typing triples (rdf:type sio:SIO_000089, cbgp:<form_type>)
#   - An sio:SIO_000115 identifier node carrying the primary_id string
#   - One attribute node per field value, using the SIO reified-attribute pattern
#   - Provenance triples in the DEFAULT graph:
#       * dcterms:modified — always written (timestamp of this write)
#       * dcterms:created  — always written; preserved from the prior version
#         on an edit (via delete_dataset_query's return value) rather than
#         reset, so creation date survives edits instead of being lost
#       * dcterms:type — always written; the FORM CLASS that produced this
#         record (e.g. cbgp:personnel_project), not the shared dbname. This
#         is what replaced project_category (a real, ontology-declared
#         field with its own default-per-form value) with something
#         structural: every record on every form gets this automatically,
#         with zero ontology configuration, because it's written directly
#         from the +form:+ parameter that's already threaded through the
#         whole save path (see CBGP::Dataset.load_from_params_and_write) -
#         nothing for an ontology editor to remember to declare, and no
#         "forgot to add has-defaults for the new form" gap possible. The
#         object is the form class URI itself, not a string, so its
#         display label resolves for free via get_label_for_id/
#         cached_label_for_id (lib/core.rb) - already generic over any
#         cbgp:<id> rdfs:label, and every form class already has one, so
#         nothing new was needed for this to work.
#
# Multiple-cardinality fields produce one numbered attribute node per value:
#   <dataset>/<questionclass>_1, <dataset>/<questionclass>_2, …
#
# @param dataset [CBGP::Dataset] the dataset to serialise
# @param oldid [String, nil] if present, the old graph is snapshotted+dropped
#   before insert
# @param form [String, nil] the specific FORM class that produced this
#   write (e.g. "personnel_project") - NOT the shared dbname. Defaults to
#   +dataset.form_type+ (the dbname) when not given, which is only correct
#   for a dbname with exactly one form - callers that know the true form
#   (i.e. +load_from_params_and_write+) must pass it explicitly.
# True if replacing a record with +old_field_count+ real fields by one with
# only +new_field_count+ looks like silent data loss rather than a genuine
# edit - the actual decision write_dataset_to_db_query's safety net acts
# on, pulled out as its own pure function so it's directly testable without
# needing to mock any part of the SPARQL-heavy write path around it (see
# [[feedback_top_level_method_stubbing]] - a bare top-level function calling
# another bare top-level function can't be reliably intercepted by
# allow(Object).to receive(...) anyway, so keeping the actual logic this
# small and pure is the more honest way to cover it).
#
# Deliberately conservative: only fires on NEAR-TOTAL loss of a record that
# previously had real substance (>3 fields down to <=1) - an HTML form
# submission always resubmits every field, so a genuine save from the live
# app never looks like this; a record that only ever had 1-3 fields to
# begin with, or an edit that trims some-but-not-nearly-all fields, is left
# alone.
def looks_like_silent_data_loss?(old_field_count:, new_field_count:)
  old_field_count > 3 && new_field_count <= 1
end

# @return [String] the complete SPARQL UPDATE query string
def write_dataset_to_db_query(dataset:, oldid: nil, form: nil)
  # dataset.form_type is the specific FORM class (that is what load_from_params_and_write
  # builds the Dataset with, to get the right fields); records are stored under the
  # form's shared DBNAME so every form on one dbname is found by the same search and
  # cross-reference lookups. Writing under the form name (as this did until 2026-10-05)
  # made e.g. a personnel_project invisible to any search of dbname "project".
  database = storage_dbname_for(dataset.form_type)
  form = dataset.form_type if form.to_s.strip.empty?
  primary_id = dataset.primary_id
  warn "WRITE DATASET primary_id is #{primary_id}\n\n"

  captured = nil
  old_values = nil
  if oldid
    old_graph_uri = "#{BASE_URI}#{database}/context/#{oldid}"
    old_values = fetch_datasets_raw_data(graph_uris: [old_graph_uri], database: database).first || {}
    detail = summarize_field_changes(fields: dataset.fields, old_values: old_values, new_dataset: dataset)

    old_field_count = old_values.keys.reject { |k| k == :dataset }.size
    new_field_count = dataset.fields.count do |f|
      dataset.respond_to?(f[:method]) && !blank_field_value?(dataset.public_send(f[:method]))
    end
    if looks_like_silent_data_loss?(old_field_count: old_field_count, new_field_count: new_field_count)
      abort "write_dataset_to_db_query: refusing to replace #{database} record #{oldid} " \
            "(previously #{old_field_count} field(s)) with one that has only #{new_field_count} - this looks " \
            'like data loss, not an edit. If this is genuinely intentional, delete the record explicitly instead.'
    end

    captured = delete_dataset_query(oldid: old_graph_uri, reason: 'superseded', detail: detail)
  end

  datasetPREFIX         = "<#{BASE_URI}#{database}/dataset/>"
  datasetgraphPREFIX    = "<#{BASE_URI}#{database}/context/>"
  datasetFragmentPREFIX = "<#{BASE_URI}#{database}/dataset/#{primary_id}#>"
  graph_uri             = "#{datasetgraphPREFIX}#{primary_id}" # Full named graph URI (used for provenance)

  # Current UTC timestamp in ISO8601 format (xsd:dateTime compatible literal).
  # Microsecond precision (6) - see delete_dataset_query's generated_at
  # comment above for why: this becomes dcterms:modified, which
  # full_timeline sorts snapshots by, and rapid-succession writes to the
  # same record (a bulk load, in particular) can otherwise land in the same
  # second.
  timestamp = Time.now.utc.iso8601(6)

  triples = []
  triples << "dataset:#{primary_id} rdf:type sio:SIO_000089 ;"
  triples << "   rdf:type cbgp:#{database} ;"
  triples << '   sio:SIO_000671 datasetfrag:primary_id .'
  triples << "   datasetfrag:primary_id sio:SIO_000300 \"#{primary_id}\" ;"
  triples << '           rdf:type sio:SIO_000115 . # sio: identifier'

  dataset.fields.each do |field|
    next unless dataset.respond_to?(field[:method])

    value = dataset.public_send(field[:method])
    next if value.nil? || (value.is_a?(Array) && value.empty?)

    questionclass = field[:questionclass]

    if field[:cardinality] == 'Multiple' && value.is_a?(Array)
      value.each_with_index do |val, index|
        next if val.to_s.strip.empty?

        this_attribute = "#{datasetPREFIX.gsub(/[<>]/, '')}#{primary_id}/#{questionclass}_#{index + 1}"
        triples << "dataset:#{primary_id} sio:SIO_000008 <#{this_attribute}> ."
        triples << "<#{this_attribute}> rdf:type cbgp:#{questionclass} ."
        triples << "<#{this_attribute}> sio:SIO_000300 #{sparql_literal(val, field[:class])} ."
      end
    else
      this_attribute = "#{datasetPREFIX.gsub(/[<>]/, '')}#{primary_id}/#{questionclass}"
      triples << "dataset:#{primary_id} sio:SIO_000008 <#{this_attribute}> ."
      triples << "<#{this_attribute}> rdf:type cbgp:#{questionclass} ."
      triples << "<#{this_attribute}> sio:SIO_000300 #{sparql_literal(value, field[:class])} ."
    end
  end

  # Provenance triples live INSIDE the record's own named graph, subject =
  # the graph's own URI (see this method's doc comment for why, and why not
  # the default graph). dcterms:created is preserved from the prior version
  # on an edit (captured by delete_dataset_query above) rather than reset,
  # so it survives edits.
  created_value = captured&.dig(:created) || timestamp
  triples << "datasetgraph:#{primary_id} dcterms:modified \"#{timestamp}\"^^xsd:dateTime ."
  triples << "datasetgraph:#{primary_id} dcterms:created \"#{created_value}\"^^xsd:dateTime ."
  triples << "datasetgraph:#{primary_id} dcterms:type cbgp:#{form} ."

  body = triples.join("\n")

  query = <<~WRITE_DATASET
    #{PREFIXES}
    PREFIX dataset: #{datasetPREFIX}
    PREFIX datasetfrag: #{datasetFragmentPREFIX}
    PREFIX datasetgraph: #{datasetgraphPREFIX}
    INSERT DATA { GRAPH datasetgraph:#{primary_id} {
    #{body}
    }
    }
  WRITE_DATASET

  # old_values (nil for a new record, the pre-edit field values for an
  # edit) is surfaced here rather than discarded, so CBGP::Triggers can
  # detect an answer-value transition at save time without a second query -
  # see write_dataset_to_db below and Dataset#old_values.
  { query: query, old_values: old_values }
end

#####################################################
######################################################
################    SEARCH   #########################
######################################################
######################################################

# Helper to strip diacritics/accents using Unicode normalization (NFKD decomposition + remove combining marks).
# This turns "ñ" → "n", "é" → "e", etc., for base-letter pattern building.
def unaccent(str)
  str.unicode_normalize(:nfkd).gsub(/[\u0300-\u036f]/, '')
end

# Helper to generate an accent-insensitive regex pattern for search terms.
# First: Unaccent the term to base letters.
# Then: For each base letter, map to a character class including common accented variants.
# Finally: Downcase and escape non-mapped chars.
#
# This allows bidirectional matching: input with/without accents matches stored with/without.
# Example: "briañ" → unaccent → "brian" → pattern "bri[aáàäâã][nñ]"
# Matches: "brian", "briañ", "Brian", etc. (with "i" flag for case-insensitivity).
def accent_insensitive_pattern(term)
  return '' if term.to_s.strip.empty?

  # First, strip accents to get base term
  base_term = unaccent(term).downcase

  # Expanded mapping for Spanish/Latin common accents (add more if needed, e.g., for other languages)
  mapping = {
    'a' => '[aáàäâãåæāăąǎǟǡȁȃȧ]',
    'e' => '[eéèëêēĕėęěȅȇȩ]',
    'i' => '[iíìïîĩīĭįıǐȉȋ]',
    'o' => '[oóòöôõøōŏőǒȍȏȫȭȯ]',
    'u' => '[uúùüûũūŭůűǔȕȗ]',
    'n' => '[nñńņňŉǹ]',
    'c' => '[cçćĉċč]',
    'y' => '[yýÿŷ]' # Added for completeness (e.g., Spanish surnames)
  }

  # Build pattern: replace each base char with its class or escaped
  base_term.gsub(/./) { |char| mapping[char] || sparql_regex_escape(char) }
end

# Escapes a single character for safe use inside a SPARQL FILTER regex(...)
# string-literal argument.
#
# NOTE: this is deliberately NOT Ruby's Regexp.escape. SPARQL's regex()
# function uses XPath F&O regex syntax, and the pattern is embedded inside a
# SPARQL string literal. Ruby's Regexp.escape escapes characters (like a
# plain space, to survive Ruby's own /x extended-mode regexes) that are
# meaningless to escape here and that SPARQL's string-literal grammar
# actually rejects — e.g. Regexp.escape(' ') => '\ ', and "\ " is not a
# legal SPARQL string escape, which previously caused a lexical error on any
# multi-word search term (e.g. "My Innovative Project").
def sparql_regex_escape(char)
  # Two layers of escaping stack here: XPath/regex-metacharacter escaping
  # (one backslash) is itself embedded inside a SPARQL double-quoted string
  # literal, whose own grammar only recognizes a fixed ECHAR set
  # (\t \n \r \b \f \" \' \\) - \. \* \( etc. are NOT valid SPARQL string
  # escapes. GraphDB passed a single backslash through leniently; Virtuoso
  # enforces the grammar and rejects it outright (SP030 "Bad escape
  # sequence"), found 2026-08-26 testing a real bulk publication load. The
  # backslash therefore has to be doubled so the SPARQL string-literal
  # parser reduces \\ -> \ first, leaving a single backslash for the regex
  # engine underneath - exactly what was intended all along.
  case char
  when '"' then '\\"' # SPARQL string escape for a quote; the regex engine just sees a literal "
  when '\\' then '\\\\\\\\' # regex-escaped backslash (\\), each doubled for the SPARQL string: four in total
  when '.', '*', '+', '?', '(', ')', '[', ']', '{', '}', '|', '^', '$' then "\\\\#{char}" # XPath regex metacharacters
  else char
  end
end

# The real search terms in +search_params+ as [questionclass, value] pairs:
# the "__not" / "__exact" / "__orempty" sibling flags and "__all" are not
# fields, and a repeatable field (cardinality Multiple) posts its values as an
# Array - one term per non-blank value (each must match; blank rows, e.g. the
# empty row a repeatable widget always shows, are not terms at all). Without
# this an Array was interpolated into the regex as its Ruby inspect string
# (["x"]), which Virtuoso rejected.
def search_field_params(search_params)
  search_params
    .reject { |k, _v| k.to_s.end_with?('__not', '__exact', '__orempty') || k.to_s == '__all' }
    .flat_map { |k, v| v.is_a?(Array) ? v.map { |x| x.to_s.strip }.reject(&:empty?).map { |x| [k, x] } : [[k, v]] }
end

# True when nothing in +search_params+ is an actual search term - e.g. a search
# form submitted with every box empty (it posts every field, all blank).
def search_terms_blank?(search_params)
  search_field_params(search_params).none? do |_k, v|
    !v.nil? &&
      ((!v.is_a?(Hash) && !v.to_s.strip.empty?) ||
       (v.is_a?(Hash) && v.values.any? { |val| !val.to_s.strip.empty? }))
  end
end

def build_search_query(search_params:, dataset_type:)
  dataset_type = validate_local_name!(dataset_type, field: 'dataset_type')
  return nil unless search_params.is_a?(Hash)

  # A "#{questionclass}__not" => "1" sibling param (checkbox on the search
  # form) negates that field's condition. Pulled out up front so the main
  # loop below only ever sees real fields, never these flag keys.
  negate_flags = search_params.keys.each_with_object({}) do |k, h|
    next unless k.to_s.end_with?('__not')

    h[k.to_s.sub(/__not\z/, '')] = true
  end
  # A "#{questionclass}__exact" => "1" sibling param (set by the result-page
  # links, see search_link_html) switches that field from the form's
  # forgiving "contains, ignoring case and accents" to an exact match on the
  # stored value - a link on one DNI must not also find every DNI that merely
  # contains those characters. Typed searches never set it.
  exact_flags = search_params.keys.each_with_object({}) do |k, h|
    next unless k.to_s.end_with?('__exact')

    h[k.to_s.sub(/__exact\z/, '')] = true
  end
  # A "#{questionclass}__orempty" => "1" sibling param widens that field's
  # condition to "matches, or has no value at all" (e.g. a project that has
  # started and has not ended: end date on/after today, or no end date).
  empty_ok_flags = search_params.keys.each_with_object({}) do |k, h|
    next unless k.to_s.end_with?('__orempty')

    h[k.to_s.sub(/__orempty\z/, '')] = true
  end
  field_params = search_field_params(search_params)
  return nil if search_terms_blank?(search_params)

  # OPTIMIZATION: Use the exact cached fields (with :questionclass, :label, etc.)
  fields = CBGP::Dataset.fields_for(dataset_type) # the form's own fields (or, for a dbname, every sharing form's)
  warn "\n\n\nFIELDS #{fields}\n\n\n" if ENV['CBGP_DEBUG_SPARQL']
  dbname, scope_form = search_scope_for(dataset_type)
  datasetPREFIX = "<#{BASE_URI}#{dbname}/dataset/>"
  datasetgraphPREFIX = "<#{BASE_URI}#{dbname}/context/>"

  query = <<~SPARQL
    #{PREFIXES}
    PREFIX dataset: #{datasetPREFIX}
    PREFIX datasetgraph: #{datasetgraphPREFIX}
    SELECT DISTINCT ?datasetgraph
    WHERE {
      #{form_scope_pattern(scope_form)}
      GRAPH ?datasetgraph {
        ?dataset a cbgp:#{dbname} .
  SPARQL

  conditions = []

  # Each field gets its own index-suffixed ?attribute_N/?value_N (or
  # ?datevalue_N) pair. Previously every condition block reused the bare
  # ?attribute/?value names, which meant combining 2+ non-date fields forced
  # a single ?attribute binding to simultaneously satisfy two different
  # `rdf:type cbgp:...` constraints - impossible under this reified
  # attribute-value model, so any 2-field search silently returned zero
  # rows. Found 2026-09-28 while building NOT support, which independently
  # needs each field scoped to its own variables so a FILTER NOT EXISTS on
  # one field can't leak into another field's match.
  field_params.each_with_index do |(questionclass, value), idx|
    field = fields.find { |f| f[:questionclass] == questionclass }

    if field.nil?
      warn "WARNING: No field found for questionclass '#{questionclass}' in #{dataset_type} – skipping this search term"
      next
    end

    attr_var = "?attribute_#{idx}"
    negate = negate_flags[questionclass]
    # NOT means "no matching value AND no value at all" (true set-complement,
    # not just 'has a non-matching value'), so negation wraps the field's
    # entire normal match pattern in FILTER NOT EXISTS rather than just
    # negating the FILTER - a record missing the attribute entirely still
    # satisfies NOT EXISTS.
    wrap = ->(block) { negate ? "FILTER NOT EXISTS {\n#{block}}\n" : block }

    # Every branch below yields the field's value variable and its match
    # CONDITION (a SPARQL expression); the triple pattern that binds the value
    # is the same for all of them. Keeping the two apart is what lets
    # "<field>__orempty" wrap them as OPTIONAL + FILTER(!BOUND || cond).
    val_var, condition, filter =
      if value.is_a?(Hash) # Date range
        start_date = value['start']&.strip
        end_date = value['end']&.strip
        next if start_date.to_s.empty? && end_date.to_s.empty?

        # Previously interpolated raw with no escaping at all - fine while
        # only a date-picker widget ever produced these, not once this same
        # path takes an MCP tool argument. validate_date! both rejects
        # anything that isn't a real calendar date and normalizes it to
        # YYYY-MM-DD, so there's nothing left for an injected value to do.
        # "today" is accepted in place of a date (resolve_date_keyword) so a
        # saved link or bookmark keeps meaning "as of the day it is opened".
        start_date = start_date.to_s.empty? ? nil : validate_date!(resolve_date_keyword(start_date))
        end_date = end_date.to_s.empty? ? nil : validate_date!(resolve_date_keyword(end_date))

        # The bound is written xsd:date("...") (Virtuoso's documented idiom
        # for date ranges), NOT "..."^^xsd:date: against the real store the
        # literal form silently dropped rows (verified 2026-10-06: <= today
        # matched 12 of 919 members, the function form all 919) while the
        # function form was right every time. The stored values themselves
        # are real xsd:date (see sparql_literal) - only the constant is cast.
        date_var = "?datevalue_#{idx}"
        bounds = []
        bounds << "#{date_var} >= xsd:date(\"#{start_date}\")" if start_date
        bounds << "#{date_var} <= xsd:date(\"#{end_date}\")" if end_date
        [date_var, bounds.join(' && '), "FILTER (#{bounds.join(' && ')})"]
      else # Text / dropdown value
        value_str = value.to_s.strip
        next if value_str.empty?

        val_var = "?value_#{idx}"

        if exact_flags[questionclass]
          # The value is compared as the stored text, verbatim: no accent
          # folding, no currency/number re-parsing (a stored "15000.50" would
          # be misread in a Spanish locale), nothing regex-shaped to escape.
          # The raw (unstripped) text is used so a value stored with
          # surrounding spaces still matches its own link.
          cond = "STR(#{val_var}) = \"#{escape_for_literal(value)}\""
          [val_var, cond, "FILTER(#{cond})"]
        elsif %w[currency number].include?(field[:class])
          # Search input is typed in the current UI language's number
          # convention (e.g. "15.000,50" in Spanish); normalize it to the
          # canonical decimal form the value is actually stored in before
          # matching, same as on save. Skip silently on unparseable input,
          # like every other search field does on a blank/invalid term.
          parsed = parse_currency_input(value_str)
          next unless parsed

          cond = "CONTAINS(STR(#{val_var}), \"#{parsed}\")"
          [val_var, cond, "FILTER(#{cond})"]
        else
          # Accent-insensitive by default for every free-text/dropdown field.
          # Previously this was opt-in per field via an ACCENT_SENSITIVE_LABELS
          # allowlist keyed on the ontology's human-readable (and
          # language-specific, and rewording-prone) field label, which is how
          # fields silently fell out of coverage - e.g. "member_name" was never
          # added, and label rewordings ("affiliation" -> "Affiliations",
          # "partner institutions" -> "Partner institutions (acronym and
          # country)") broke the exact-string match for fields that WERE
          # supposedly covered. Matching is now unconditional, so there is no
          # list to fall out of sync.
          pattern = accent_insensitive_pattern(value_str)
          next if pattern.empty?

          cond = "regex(STR(#{val_var}), \"#{pattern}\", \"i\")"
          [val_var, cond, "FILTER #{cond}"]
        end
      end

    match = <<-PATTERN
        ?dataset sio:SIO_000008 #{attr_var} .
        #{attr_var} sio:SIO_000300 #{val_var} .
        #{attr_var} rdf:type cbgp:#{questionclass} .
    PATTERN

    conditions <<
      if negate
        # NOT wins over "or empty" (they would contradict each other).
        wrap.call("#{match}#{filter}\n")
      elsif empty_ok_flags[questionclass]
        # "matches, or has no value at all": the value is optional and the
        # filter lets an unbound one through. The FILTER must sit OUTSIDE the
        # OPTIONAL group, or it would only restrict the optional part.
        "OPTIONAL {\n#{match}}\nFILTER (!BOUND(#{val_var}) || (#{condition}))\n"
      else
        "#{match}#{filter}\n"
      end
  end

  if conditions.empty?
    warn 'WARNING: No valid search conditions generated – returning empty results'
    return nil
  end

  query += conditions.join("\n")
  query += <<~SPARQL
      }
    }
  SPARQL

  warn "Generated search query:\n#{query}\n\n\n" if ENV['CBGP_DEBUG_SPARQL']
  query
end

# "__all" => "1" in the params is the "Show all records" request: every
# record of the form/dbname, whatever else was typed. It is deliberately a
# param the search routes pass on and NOT a default for blank terms - the
# lookups (primary-id match, DOI check, related records) search on a single
# key, and an empty key there must keep meaning "no match".
def show_all_requested?(search_params)
  search_params.respond_to?(:[]) && search_params.respond_to?(:key?) && search_params['__all'].to_s == '1'
end

def execute_search(dataset_type:, search_params: {}, broad: false)
  if broad || show_all_requested?(search_params) || search_params.empty? # Treat empty params as broad request
    warn "[BROAD SEARCH] Fetching all graphs for #{dataset_type}" if ENV['CBGP_DEBUG_SPARQL']
    return search_for_all_graphs(dataset_type: dataset_type)
  end

  query = build_search_query(search_params: search_params, dataset_type: dataset_type)
  warn "Generated search query:\n#{query || 'NIL QUERY'}" if ENV['CBGP_DEBUG_SPARQL']
  return [] unless query

  results = DATABASE.query(query)
  warn "Search results count: #{results.count}" if ENV['CBGP_DEBUG_SPARQL']
  results.map { |r| r[:datasetgraph].to_s }
end

def search_for_all_graphs(dataset_type:)
  query = search_all_graphs_query(dataset_type: dataset_type)
  warn "\n\n\nBROAD SEARCH QUERY IS #{query}\n\n\n" if ENV['CBGP_DEBUG_SPARQL']

  return [] unless query

  results = DATABASE.query(query)
  warn "Search results: #{results.map { |r| r.to_h }.inspect}" if ENV['CBGP_DEBUG_SPARQL']
  results.map { |result| result[:datasetgraph].to_s } # Return array of graph URIs
end

def search_all_graphs_query(dataset_type:)
  dataset_type = validate_local_name!(dataset_type, field: 'dataset_type')
  # [Unchanged early-exit guard]

  dbname, scope_form = search_scope_for(dataset_type)

  query = <<~SPARQL
    #{PREFIXES}
    SELECT DISTINCT ?datasetgraph
    WHERE {
      #{form_scope_pattern(scope_form)}
      GRAPH ?datasetgraph {
      ?s a cbgp:#{dbname}
      }
    }
  SPARQL

  warn "Generated search query:\n#{query}\n\n\n" if ENV['CBGP_DEBUG_SPARQL']
  query
end

# Fetches metadata/details for a dataset graphs identified by their URIs.
# The details are pulled from a SPARQL endpoint using fields defined in a "questionnaire"
# for the given dataset_type (e.g., specific attributes like title, description, etc.).
# Returns an array of hashes, one hash per dataset URI, containing only the fields that
# actually have values.
def fetch_datasets_raw_data(graph_uris:, database:)
  database = validate_local_name!(database, field: 'database')
  graph_uris = [graph_uris] unless graph_uris.is_a? Array
  return [] if graph_uris.empty?

  # OPTIMIZATION: Use cached exact fields
  fields = CBGP::Dataset.fields_for(database)

  # Build SELECT: ?graph + all ?questionclass vars, plus each field's own
  # attribute-node variable - needed to reconstruct Multiple-cardinality
  # field order below (see the sort_by in the grouping step).
  select_clause = '?graph ' + fields.map { |f| "?#{f[:questionclass]} ?attribute#{f[:questionclass]}" }.join(' ')

  # Build VALUES clause for all graphs
  values_clause = "VALUES ?graph { #{graph_uris.map { |g| "<#{g}>" }.join(' ')} }"

  # Build WHERE: OPTIONAL blocks per field
  where_clause = fields.map do |f|
    <<~SPARQL
      OPTIONAL {
        GRAPH ?graph {
          ?dataset sio:SIO_000008 ?attribute#{f[:questionclass]} .
          ?attribute#{f[:questionclass]} sio:SIO_000300 ?#{f[:questionclass]} .
          ?attribute#{f[:questionclass]} rdf:type cbgp:#{f[:questionclass]} .
        }
      }
    SPARQL
  end.join("\n")

  # Full batched query
  query = <<~SPARQL
    #{PREFIXES}
    SELECT #{select_clause}
    WHERE {
      #{values_clause}
      #{where_clause}
    }
  SPARQL

  warn "BATCHED FETCH QUERY:\n#{query}\n\n" if ENV['CBGP_DEBUG_SPARQL']

  result_set = DATABASE.query(query)

  # Group results by graph (handles multi-row per graph for multi-valued fields)
  grouped = result_set.group_by { |r| r[:graph].to_s }

  grouped.map do |graph_uri, rows|
    details = { dataset: graph_uri }

    fields.each do |f|
      field_sym = f[:questionclass].to_sym

      if f[:cardinality] == 'Multiple'
        # Reconstruct write-time order: each attribute node's own URI ends
        # in "_<N>" (the 1-based array index write_dataset_to_db_query gave
        # it - see that method's doc comment), which SPARQL's row order does
        # not preserve on its own. Sorting by that before flattening/uniq-ing
        # is what makes e.g. publication_authors come back in the original
        # author order (first/last author position matters for biology
        # papers) - found 2026-08-26, this previously silently returned
        # authors in whatever arbitrary order Virtuoso's query planner chose.
        attr_sym = :"attribute#{f[:questionclass]}"
        ordered_rows = rows.sort_by { |r| multiple_field_sort_key(row: r, attr_sym: attr_sym) }
        values = ordered_rows.flat_map { |r| r[field_sym]&.to_s }.compact.uniq
        details[field_sym] = values unless values.empty?
      elsif rows.first&.bound?(field_sym)
        details[field_sym] = rows.first[field_sym]&.to_s
      end
    end

    warn "BATCHED DETAILS FOR #{graph_uri}: #{details.inspect}" if ENV['CBGP_DEBUG_SPARQL']
    details
  end
end

# Sort key for reconstructing Multiple-cardinality field order (see
# fetch_datasets_raw_data). A row with no attribute bound (this field wasn't
# the one that matched in this particular OPTIONAL row) or a URI with no
# numeric suffix sorts last rather than raising, so a partial or unexpected
# record shape still returns something sensible instead of crashing the
# whole batch fetch.
def multiple_field_sort_key(row:, attr_sym:)
  uri = row[attr_sym]&.to_s
  return Float::INFINITY unless uri

  match = uri.match(/_(\d+)\z/)
  match ? match[1].to_i : Float::INFINITY
end

# graph URI => form class (e.g. "personnel_project") for many records at once,
# read from the dcterms:type stamp each record carries; a record with no stamp
# is simply absent. One query for the whole results page. Never raises (the
# page is still useful without its "Record type" column).
def batch_retrieve_record_forms(graph_uris:)
  return {} if graph_uris.empty?

  query = <<~SPARQL
    #{PREFIXES}
    SELECT ?graph ?form
    WHERE {
      VALUES ?graph { #{graph_uris.map { |g| "<#{RDF::URI(g.to_s)}>" }.join(' ')} }
      ?graph dcterms:type ?form .
    }
  SPARQL

  DATABASE.query(query).each_with_object({}) do |row, hash|
    hash[row[:graph].to_s] = row[:form].to_s.split('#').last
  end
rescue StandardError => e
  warn "[RECORD-FORM] could not read the forms of #{graph_uris.size} results: #{e.class}: #{e.message}"
  {}
end

def batch_retrieve_dataset_ids(graph_uris:)
  return {} if graph_uris.empty?

  # Build VALUES for all graphs
  values_clause = "VALUES ?graph { #{graph_uris.map { |g| "<#{g}>" }.join(' ')} }"

  query = <<~SPARQL
    #{PREFIXES}
    SELECT ?graph ?id
    WHERE {
      #{values_clause}
      GRAPH ?graph {
        ?dataset sio:SIO_000671 ?idnode .
        ?idnode sio:SIO_000300 ?id ;
          rdf:type sio:SIO_000115 .  # identifier
      }
    }
  SPARQL

  warn "BATCHED PRIMARY_ID QUERY:\n#{query}\n\n" if ENV['CBGP_DEBUG_SPARQL']

  results = DATABASE.query(query)

  # Build hash: graph_uri => primary_id (string)
  results.each_with_object({}) do |row, hash|
    graph = row[:graph].to_s
    id = row[:id]&.to_s
    hash[graph] = id if id
  end
end
