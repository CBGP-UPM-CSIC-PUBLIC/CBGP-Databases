# Changelog

All notable changes to this project are documented here. Format loosely follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

Entries up to and including 0.5.0 are reconstructed retroactively from git
history, since formal per-release versioning wasn't tracked from the start.
Only two versions (0.0.3 and 0.2.0) correspond to an explicit commit message;
the rest are grouped by theme/date as a best-effort mapping. From this point
forward, every release ships with a matching `VERSION` file bump and an entry
here.

## [Unreleased]

## [0.20.0] - 2026-10-13

No ontology change.

### Added
- **Charts for the AI agent**: `chart_over_time` (a count or total over the years: bars,
  stacked, percent, lines, areas) and `chart_breakdown` (by category, as things are now).
  Each fetches the data itself, draws it on the server in the institute's theme and returns
  a **PNG image by default** (the model reads only a file name, not the picture). Two
  shapes: `slide` (16:9) and `report` (3:2, for a Word column). Every chart has a title and
  a caption saying what was counted, when, and how many records were read; records with no
  value appear as "(none)" and anything excluded is reported. `output: html` returns the
  interactive page instead (SVG and PNG downloads in both shapes, and the numbers as a file
  that opens in Excel); `both` returns the page and the PNG. English and Spanish.
- **`aggregate`**: counts, totals and averages by category and by calendar year, computed on
  the server from a lean fetch (a large form takes well under a second). Years can be taken
  from a date, from "active at the end of the year", "active during the year", or spread
  over the years a commitment covers.
- **Branding in a mounted file**: colours, font and footer line come from `theme/theme.yml`
  (or the path in `CBGP_THEME_FILE`), re-read whenever the file changes, validated, with a
  per-setting fallback so a typo never stops a chart. See `theme/theme.example.yml`. Without
  a file the built-in CBGP look is used. The timeline uses the same theme.
- Documentation (English and Spanish): charts, branding the charts, and what each tool costs
  in tokens (`utilities/mcp_cost_report.rb` measures it).

### Changed
- **`render_timeline` now returns a PNG image by default**, like the charts. The interactive
  page made some agents paste its source into their answer; ask for `output: html` to get it.
- The instructions sent to the agent when it connects now cover `aggregate` and the chart
  tools (including "forms that share a storage name are charted together in one call", "call
  one tool at a time" and "never write plotting code"), and the tool summaries open with the
  words people use ("Make a bar chart of ..."). The tools together add about 7,250 tokens to
  every request; the cost report shows where they go.

### Upgrading
**Rebuild the image** (it needs `rsvg-convert` and a font, already in the Dockerfile since
0.19.0). To brand the charts without rebuilding, copy `theme/theme.example.yml` to
`theme/theme.yml` and mount `./theme:/server/theme:ro` (see `docker-compose.yml`). Then in
Hermes run `/reload-mcp` and start a new chat; tool lists and instructions are read when a
session starts. The Spanish text of the new documentation and of the charts' captions has not
had a native read-through, and the colours are sampled from the CBGP logo until official ones
are supplied.

## [0.19.0] - 2026-10-09

**Ontology change** (CBGP-Ontology `bb52835`): every form, and the `cbgp:forms` class,
now has an `rdfs:comment` in English and Spanish saying what its records are. Push and
publish the ontology first; the application reads these, and works (without them) if
they are missing.

### Added
- **AI agent endpoint** (`POST /mcp`, Model Context Protocol). Read-only access for an
  agent such as Hermes: `describe_form`, `search_records` (text, exact value, date
  range, `today`/`hoy`, "or no value", count-only with `limit: 0`; fixed-list values by
  id or by label in either language), `get_record`, `linked_records` (follows the
  ontology's declared cross-references in both directions), `record_history` (versions
  with field-level changes) and `render_timeline`. Nothing in it names a form or a field:
  it all comes from the ontology. Off unless `MCP_TOKEN` is set (bearer token; a blank
  value never means "open"). Only the staff-facing forms are offered. Replaces the first
  MCP design, which was never released.
- **What the agent is told about the data comes from the ontology**: the dataset
  description and each form's description (first sentence in the one-line list, the rest
  on request) are put into the server instructions and the tool descriptions, in both
  languages, cached per loaded ontology (a refresh invalidates it).
- **Timelines**: a labelled "today" line; bars, points and "still going" bars; the page
  has a "Download SVG" link and a "Download PNG" button (made in the viewer's browser);
  `output: png` returns a PNG image instead (made on the server by `rsvg-convert`).
- `check_ontology.rb` warns about a form, or the dataset itself, with no description in a
  required language (`form_without_description`).
- Documentation (English and Spanish): "Asking questions through an AI agent" and the
  `MCP_TOKEN` section in Configuration.

### Changed
- The Docker image installs `librsvg2-bin` and `fonts-dejavu-core` (the PNG converter and
  a font). **Rebuild the image**; without them only the PNG attachment is unavailable.
- `.env.example` lists `MCP_TOKEN`; the login filter lets `/mcp` through to its own token
  check.

### Upgrading
Set `MCP_TOKEN` in `.env` to enable the endpoint, then recreate the container (a plain
restart does not re-read `.env`). The Spanish text of the new page and of the form
descriptions has not had a native read-through.

## [0.18.3] - 2026-10-07

No ontology change.

### Fixed
- **Spanish sessions crashed on any record holding a number or currency value**
  (found on the demo server: searching funding commitments in Spanish gave
  "Invalid value 60.00 for type number"). Stored numbers are canonical ("60.00");
  loading a record - a search result, the edit page, a related-records panel - and
  storing a calculated result both went through the setter that parses what a person
  *types*, in the viewer's notation, and the Spanish form of 60.00 is "60,00". Stored
  values are now always read as canonical (`CBGP::Dataset.reading_canonical_numbers`);
  what a person types is still read in their own language. Only Spanish was affected.

## [0.18.2] - 2026-10-07

**Needs CBGP-Ontology `851d3a0` or later** (live at w3id.org/CBGP-App).

### Added
- **"Today" beside date boxes.** On every search date range, a tick box
  **Today (changes daily)** under each bound searches with the day the search is
  run (a *relative* statement, not a date - the same search tomorrow finds
  different records). A results page that used it says what it was read as and
  that it is not fixed. On the data-entry forms a **Today** button fills the box
  with today's real date; a saved record never holds the word. Documented
  (EN + ES) in Search & Queries and Data Entry.
- **A search is bookmarkable.** The search form still posts, but is answered with
  a redirect to the same search as a plain link holding only the filled-in boxes
  (`/cbgp/query-dataset/<form>?...`), so the results page can be bookmarked,
  shared and re-run; with Today ticked it is re-run as of the day it is opened.
- A second horizontal scrollbar above wide results tables (`table_scroll.js`).
- **Saving goes to the record's own address.** After a save that did not return
  to a search, the record opens at `/cbgp/dataset/<form>/<id>` with a
  "Record saved." notice, so the address is bookmarkable and refresh no longer
  re-submits the form.
- `check_ontology.rb` (CBGP-Ontology) now rejects a primary-id field that is
  repeatable (`primary_id_repeatable`).

### Changed
- `project_internal_code` is single-valued (it is the project's identifier).
  **Needs CBGP-Ontology `851d3a0` or later, which makes it `Single` and adds the new
  interface texts** (`ui_search_today`, `ui_search_today_note`, `ui_entry_today`,
  and the new wording of `ui_typeahead_stored_value`).
- Lookup boxes say "Currently selected value" (was "Stored value") and show it
  prominently; form row titles are smaller.
- Results table: removed an empty first column and a second, nested white card.
- The related-records panel (e.g. a member's other commitments) is now a proper
  white card with readable text and table.

### Fixed
- A single-valued field that received a list (a page opened while the field was
  still repeatable, saved after the ontology made it single) stored the text of
  the list, e.g. `["UI-PROJ-1"]`, silently breaking every lookup by that value.
  It now takes the one value, or refuses several with a clear message.

## [0.18.1] - 2026-10-07

### Fixed
- **Lookup lists (PI, members, other cross-references).** The suggestion list
  stopped working once an accented letter was typed (`Alarcón`) and showed only
  the surname. It is now a purpose-built list (`app/public/js/typeahead.js`)
  that shows exactly what the server returns: matched ignoring accents and
  capitals, each person shown as "Surname(s), Name", with the stored identifier
  beside any two choices that would otherwise read alike. Search is still on the
  surname only.
- New ontology property `local:label-companion` (on the label field, e.g.
  `member_surnames` -> `member_name`) says which fields follow the label; it
  applies to the suggestions, the text beside a stored value and related-record
  lists. **Needs CBGP-Ontology `b1439bf` or later**; without it labels
  are the surname alone, as before. `check_ontology.rb` validates it.

## [0.18.0] - 2026-10-07
Search across every kind of record that shares a storage name ("what projects
are running now?"), Show all records, curating a member's project submission,
dates stored as real dates, Funding Commitments, a rewritten and verified
Backup & Migration guide with a portable export, and a safer Docker image.

**Needs CBGP-Ontology `4a537e5` or later** (live at w3id.org/CBGP-App): this
release removes `project_type` and the project-level `project_dni_nie_pas`,
replaces the Personnel "Responsible PI" with the one shared PI field, makes the
project dates required only once Awarded, and adds interface texts.
**Existing data:** records written before this release hold their dates as
text; convert them once with `utilities/retype_dates.rb` (see Backup &
Migration). **Images before this one** (0.17.0 and earlier) were built without a
`.dockerignore` and contain the build machine's `.env` and local database
files; do not use or publish them, and change any password that was in that
`.env`.

### Added
- **`.env.example`**, the settings template the documentation always told
  people to copy but which did not exist (and which `.gitignore` would have
  hidden); a spec keeps it in step with the settings the code reads.
- **Portable N-Quads export and import for Virtuoso**
  (`utilities/virtuoso_nquads.sh`, with OpenLink's own dump procedure in
  `utilities/virtuoso_dump_nquads.sql`): writes a whole store as gzipped
  N-Quads, keeping every record's named graph, and loads such files into a new
  store. Verified on the real current and history stores: exported and imported
  into brand-new stores, a checksum over every statement of the application's
  graphs matched exactly. It is the vendor-neutral second copy the old GraphDB
  setup had; documented in Backup & Migration (EN and ES), including a weekly
  cron recipe.
- **Documentation brought up to date** (English and Spanish, the whole
  site). New: the search features (the all-types entry, Show all records,
  `today`, "or no value", the "what is running now?" recipe, Record type and
  the value links), curating a member's project submission and the project
  forms, conditionally required fields, typed dates, and interface text in the
  ontology. **Backup & Migration is rewritten for Virtuoso** (it still
  described GraphDB): online backup, cold copy, a nightly script, restore and
  server migration, every command run for real and each restore compared with
  the original store. Corrected: the data-model worked examples (they named
  ontology nodes that no longer exist), the Time Travel examples (fields that
  no longer exist), the DOI importer's matching rules, "Personnel" → "Member",
  export columns. The Spanish pages that were behind (Installation,
  Configuration, Backup) are translated again.
- **Project forms: one shared PI, a Comments box, and two fields removed.**
  Every project form (and the user-facing one) now has the same PI field
  (`project_pi_nie`, a member lookup, required) - Personnel projects had their
  own "Responsible PI"; the user form now says who is responsible for what it
  submits. A free-text **Comments** box (`project_comments`) on the user form
  lets a member pass extra information to the administrators; it is in the
  notification email and carries over to the curated record. Removed:
  `project_type` (the kind of project is decided when a submission is curated)
  and the project-level `project_dni_nie_pas` (people link to a project via
  the beneficiary, PI/co-PI and funding commitments).
- **Curating a record submitted through a user-facing form.** A record still on
  a user-facing (simplified) form shows administrators a panel above what was
  submitted: "review it, then curate it as" a link per Core form stored under
  the same dbname. Choosing one opens the same record under that form (nothing
  changes until saving; "back to the submitted view" is offered) and lists any
  value the submitter entered that the chosen form has no field for. Saving
  re-stamps the record with that form, keeping its primary ID and recording
  the earlier version in the history. Only records on a user-facing form, and
  only for administrators; a curated record's form stays fixed. Generic: any
  dbname with user-facing and Core forms.
- **Conditionally required fields** (`local:has-conditional-requirements`): a
  field can be required only when another field has a given answer, declared
  in the ontology and checked by `check_ontology.rb`. A small note beside the
  field says when it is required. The start and end dates of the project
  forms are now required only once the project is Awarded, so a pending
  application (no dates yet) can be saved.
- **Search across every kind of record that shares a storage name** ("what
  projects are running now", whichever project form wrote them). The Query
  list gets one extra entry per dbname several forms store under ("Projects
  (all types)", named in the ontology, with a generic "<name> (all types)"
  fallback); it is never offered for adding data. Its search form and result
  columns are only the fields all the (Core) forms have in common; each
  record's own form is still shown and its edit link opens it under that
  form. Entirely generic: no record type is named in code.
- **Show all records**: a link on every search page lists every record. A
  search form submitted with every box empty now says nothing was entered
  (and offers that link) instead of "No results found".
- **"Running now" searches**: a date bound may be `today` (resolved when the
  search runs, so a saved link stays current), and every search field has an
  "or no value" tick box (`<field>__orempty=1`) matching records whose value
  fits or is missing - e.g. `project_start_date[end]=today`,
  `project_end_date[start]=today`, `project_end_date__orempty=1` is "started
  and not ended, no end date counts as running". Status etc. combine as usual.
- **Dates are stored as real dates.** Every date was being saved as a plain
  string, and Virtuoso silently mis-answers range searches against them
  ("started by today" returned nothing; "started before 2010" returned 12 of
  22 members). A date-picker field now always counts as a date (even where
  the ontology declared it a string), is validated on save, and is written as
  an `xsd:date`; the search bound is written as `xsd:date("...")`, Virtuoso's
  documented form (the `"..."^^xsd:date` literal form dropped rows against
  the real store). `utilities/retype_dates.rb` converts existing records
  (current and history store; `--dry-run` first). Ontology: seven date
  fields now declare class Date.
- **Search arrows on the edit page** (admins only): beside each field's label, a
  small arrow per value the record currently stores opens the same exact-match
  search as the results-page links, in a new window so unsaved edits are not
  lost. Uses the stored value (not what is being typed) and the same rules as
  the results page (cross-references go to the referenced record; prose,
  numbers, dates and URLs get none). One change in `_question.erb`
  (`field_search_links_html`, `lib/core.rb`); no per-widget changes. Non-admin
  logins see none.
- **Record type column on every search result**: each row says what kind of
  record it is (e.g. "Personnel Project" vs "National and Regional Research
  Projects"), per row, so a search of a shared database such as `project` can
  be read at a glance. It comes from the `dcterms:type` stamp every record
  carries, read for the whole page in one query (`batch_retrieve_record_forms`),
  named with the ontology's own (bilingual) form labels. The type is a link
  listing every record of that form; a record without a stamp shows "-". Also a
  plain-text column in the TSV download. No ontology change.
- **Interface hints follow the selected language** (first step; Spanish drafted,
  pending review by a Spanish speaker): the cross-reference typeahead hint ("Type
  at least 2 characters of the Surname(s) to search existing member..." /
  "Escriba al menos 2 caracteres de «Apellido(s)» para buscar en «miembro»..."),
  its captions (remove / add another / stored value / clear), and the search
  form placeholders and NOT caption. As with every other label, the texts live
  in the ontology: 15 subclasses of the new `cbgp:ui-text`, one per text, each
  with English and Spanish `rdfs:label`s (a `%{name}` in a label is filled in
  by the application). New `ui_text(key, **vars)` helper (`lib/ui_text.rb`);
  `/cbgp/refresh` re-reads them; the record kind named in a hint is the
  ontology's own localized form label. `check_ontology.rb` (CBGP-Ontology)
  now also checks the `%{...}` names match across languages. **Needs the
  ontology change pushed first.** The rest of the interface text (headings,
  buttons, messages, pop-ups) is still English and moves onto the same
  mechanism next.
- **Every value is a link**: each value on
  the search-results table, and in the related-records panels, is a link to an
  exact-match search for itself - a DNI finds that person, a category all
  records in it, a project code that project. Always a search, never a direct
  link to one record, so one rule covers every kind of value. A cross-reference
  value (e.g. a commitment's member) searches the referenced form's key field;
  controlled-vocabulary values link on the stored value while showing the
  label. Plain text, not links: prose (`textfield` widgets, and any value
  containing a line break) and numbers, amounts and dates (judged on widget and
  class); `url` fields keep their own external link. The TSV
  download is untouched. Plumbing: `GET /cbgp/query-dataset/:database` now
  answers as well as POST, and a `<field>__exact=1` sibling parameter (like
  `__not`) makes that one field an exact match - typed searches keep the
  forgiving "contains, ignoring case and accents". New helper `search_link_html`
  (`lib/core.rb`); no new ontology terms. The results table's record link now
  reads **VIEW/EDIT** instead of EDIT: people mostly click it to look at a
  record, and being able to edit it is a bonus.
- **Funding Commitments** (member x project share of salary cost): a new Core
  form `funding_commitment` (own dbname `commitment`) with a member xref, a
  project xref, a percentage, start/end dates and notes. One record per
  member-and-project pair. A changed split is recorded by closing the old
  record (end date) and adding a new one, so the data is a dated ledger.
  Entirely ontology-defined - no commitment-specific code. A Personnel
  Project's beneficiary gets an explicit 100% commitment like any other.
- **Related-records panels** (`local:has-related-records`): a generic
  ontology facet by which a form lists the records of another form that point
  back at the open record, with an optional "sum this field over the rows
  active, warn if it differs from an expected total" rule (`lib/related_records.rb`,
  `_related_records.erb`). Used for a member's commitments, a project's funded
  staff, and a commitment's sibling commitments (`local:related-key-field`).
  - **Warnings look ahead**: checked for today and every future date a record
    starts or stops ("adds up to 110.00 from 2026-10-14"), each change reported
    once; past periods and dates with nobody funded are ignored. Advisory only,
    computed on read, never stored; a 0.05 tolerance covers 2-decimal rounding.
  - **Shown where you need them**: the record page, a notice after saving, and a
    "Check these" banner on commitment search results (one check per member,
    capped at 40 with a note when more were not checked).
  - Fails open - a bad panel declaration can never stop a record opening.
  - "Add a new ..." in a panel opens pre-filled with the link back to the open
    record (`?<questionclass>=<key>` accepted on a blank add form for
    cross-reference fields only - `CBGP::Dataset#prefill_references`).
- **URL widget** (`cbgp:url`, object class `URL`) and the **Application URL**
  field (see Changed). `parse_http_url` / `valid_http_url?` / `url_link_html`
  in `lib/core.rb`.
- `number` widget class in the ontology (the locale-aware `_number.erb` widget
  already existed in code with no ontology widget type).
- **Saving an edit returns to the search results** it was reached from (new
  `GET /cbgp/last-search/:database`; delete uses the same helper) with a
  "Record saved." notice, plus a warning when a panel is out of balance. A new
  record, or an edit not reached via a search, still shows the saved record.
  The results page now actually displays flash messages (it never did, so
  "Record deleted" was never seen).
- **Cross-reference search boxes say what they search** and that nothing
  happens before 2 characters, from the field's own ontology label - e.g.
  "Type at least 2 characters of the Surname(s) to search existing member..."
  (on add/edit and search forms, including "add another" rows).
- **Search forms get the same name typeahead as the add/edit forms** for
  cross-reference fields (search by surname; the stored NIE is what matches).
- `:references_label` in `CBGP::Dataset.fields_for` field descriptors.
- Generic **dbname fallback**: `get_questionnaire_sections_query` (hence
  `fields_for`, `key_method_for_form`) resolves a shared `local:dbname` that is
  not itself a form class (e.g. `project`, since the project-fields split) to
  the union of its forms' fields; `fields_for` de-duplicates a question class
  that sits in several sections. Without it a cross-reference to `project`
  loaded zero fields and stored UUIDs.
- **Ontology checker**, in CBGP-Ontology (`check_ontology.rb`,
  `test_check_ontology.rb`, `SARA_README.md`) - standard-library Ruby, no gems.
  Reports by class name and **line number** any label with no language tag,
  any labelled class missing an English or Spanish label, a blank label, a form
  with no `form-category`/`dbname`/`has-fields`, and a `form-category`/`dbname`
  without `xml:lang`. Exit status 1 on errors. Untagged comments and duplicate
  labels are warnings only (untagged comments are simply not shown to users and
  are often deliberate editor notes). This repo has the gate
  (`spec/lib/ontology_check_gate_spec.rb`): the suite fails, naming the class,
  if the ontology file it loads has an error.
- **Readable SPARQL errors**: `CBGP::SparqlClient` (read clients) and the update
  client now show Virtuoso's own message plus the offending query. Previously a
  rejected query surfaced as an unrelated `Encoding::CompatibilityError`
  whenever the reply or the query had a non-ASCII character (sparql-client
  joins the raw-byte reply with the UTF-8 query text to build its message).
  e.g. `Virtuoso 37000 Error SP030 ... End-of-line in a short double-quoted
  string ... SPARQL query: SELECT ...`.

### Changed
- **`project_application_code` -> `project_application_url` ("Application
  URL")**, a full link to the call (e.g. the European Commission topic page
  with its query string), not the call identifier - requested by the admin
  team. Only a complete http(s) address is accepted; a bare identifier, `www.`
  addresses and `javascript:`/`data:`/`ftp:` URLs are refused with a message,
  never "fixed up" or guessed. **Required on all project forms**, private
  projects included (by decision: any real address will do - keep the interfaces
  consistent), **and on the user-facing project form**, which previously had no
  required fields at all. Stored as typed (trimmed); shown as a
  `target=_blank rel="noopener noreferrer"` link in search results and beside
  the field when editing; plain text in the TSV export; searched as a text
  filter. Whether a valid link goes to the right place is not checked.
- Project-side member cross-references key on the member's **DNI/NIE/PAS**
  instead of ORCID (not every member has one): `project_pi_orcid` ->
  `project_pi_nie`, `project_main_copi_orcid` -> `project_main_copi_nie`,
  `beneficiary_orcid` -> `beneficiary_nie`,
  `personnel_project_responsible_pi_orcid` -> `personnel_project_responsible_pi_nie`
  (classes, methods, labels); `project_dni_nie_pas` is now a member
  cross-reference too. `publication_cbgp_authors` deliberately stays on ORCID.
  No data migration - the database held no real data.
- `member_projects` (free text, unvalidated) removed from the Member form; a
  member's projects are now derived from their commitments.
- Search results HTML-escape cell text (it was printed raw).
- The cross-reference widget HTML-escapes stored and pre-filled values (it
  printed them raw).

### Fixed
- **The Docker image no longer contains secrets or local data.** There was no
  `.dockerignore`, so `COPY . /server` put the real `.env`, the whole local
  Virtuoso database (`virtuoso-data/`), the built docs and `.git` into every
  image (about 233 MB of application directory, now 1.3 MB). Added a
  `.dockerignore`, with a spec that keeps the secrets out.
- **A record is always edited under the form that wrote it.** Opening
  `/cbgp/dataset/<dbname>/<id>` (e.g. `project`, which several forms share) showed
  the fields of every form on that dbname, and saving it would have stamped the
  record with the dbname instead of its real form, dropping it out of that
  form's searches. It is now redirected to `/cbgp/dataset/<its form>/<id>`
  using the record's `dcterms:type` stamp (`get_record_form`); records with no
  stamp open as before. Surfaced by the new search links (a search of `project`
  links its results to the `project` URL).
- **Records were stored under the form name instead of the form's shared
  `local:dbname`.** `write_dataset_to_db_query` took the storage "database" from
  `dataset.form_type` (the specific form), so a `personnel_project` was written
  to `.../personnel_project/context/<id>` and was invisible to any search or
  cross-reference lookup on the dbname `project`. Now written under the dbname
  (`storage_dbname_for`), with `dcterms:type` still stamping the true form.
  Found by a live smoke test; unnoticed only because no project records existed.
- **Search of a multi-form dbname found nothing**: `execute_search` now takes a
  form or a dbname - a form is searched under its dbname and restricted to the
  records that form wrote (`dcterms:type`); the dbname covers every sharing form.
- **The external-primary-id upsert lookup** searched the form name rather than
  the dbname and was handed a whole Array for a repeatable primary-id field
  (`project_internal_code`), which Virtuoso rejected (a 500).
- **Searching a repeatable field** (an Array of values) built an invalid regex
  and 500'd; each non-blank value is now its own term and blank rows are ignored.
- **A double quote or backslash in a search term broke the SPARQL query**:
  `sparql_regex_escape` emitted `\\"` for a quote (ending the string literal
  early) and three backslashes for a backslash. The old spec only checked the
  output *contained* `\"`, which `\\"` also does; the new specs check the query
  parses.
- **The cross-reference typeahead offered `["ABC-1"]`** (an Array's `to_s`) as
  the value to store when the referenced key field is repeatable (a project's
  internal code): now one plain suggestion per key value.
- **The European and Private research project forms were missing from the Add
  and Query menus**: their `form-category`/`dbname` had no `@en` tag and the
  menu query matched `"Core"@en` exactly. Tagged in the ontology, and the query
  now compares the category as plain text so a missing tag cannot hide a form.

### Removed
- `CBGP::Dataset#validate_references` and the per-field `<method>_target_form` /
  `<method>_key_method` helpers: dead since March 2026 (they read
  `references_target_form` / `references_via_class`, which `fields_for` has not
  emitted since), so the "[FOREIGN-KEY] no match" warning never fired.
  Cross-reference lookup itself is unaffected.

### Tests and docs
- 928 examples (from ~313). About 400 are one parameterised spec,
  `weird_identifiers_spec.rb`: project identifiers (internal code, call title)
  with arbitrary characters - regex metacharacters, quotes, backslashes,
  HTML/SPARQL injection, non-ASCII and real European Commission / ERC / MSCA /
  AEI grant numbers - through search, write, save, panel matching, the
  pre-fill link and page rendering; also run by hand against live Virtuoso.
  Each fix above has a spec that fails without it.
- Docs (EN + ES): `data_model.md` worked example (a record pointing at two
  others, related-records panels); `admin/data_entry.md` (funding commitments,
  web address fields); `admin/cross_references.md`. The Spanish is machine-
  drafted and awaits a manual check.

## [0.17.0] - 2026-08-25
### Fixed
- Test fixtures updated to match Sara's project-fields ontology
  restructuring (the old shared `project` form, distinguished by
  `dcterms:type`, replaced by `european_research_project`/
  `national_regional_research_project`/`private_research_project`/
  `personnel_project`): `display_labels_spec.rb`, `dcterms_type_spec.rb`,
  `history_capture_spec.rb`, `dataset_classes_currency_spec.rb`,
  `search_accent_spec.rb`, `form_required_fields_spec.rb`,
  `form_defaults_spec.rb`, `form_formulas_spec.rb` all re-anchored to real
  fields on the new forms. Confirmed the application itself has zero
  hardcoded field names anywhere in `lib/`/`app/` - only these test
  fixtures needed updating; the ontology-driven design held.
- A project-wide ontology sanity/validation pass ahead of the beta
  release, checking every form's `local:requires-field`/`local:has-formulas`/
  `local:has-defaults` targets actually resolve, plus every formula's
  Dentaku variable names against real fields. Found and fixed 5 real,
  entirely silent bugs directly in `CBGP-Ontology` (`59d1a2f`, `8870fc7`) -
  none of these ever raised an error, which is exactly why a systematic
  audit was needed rather than relying on the test suite alone:
  - `project_funding_entity` (required on Personnel Project) was missing
    `local:question-order`, so it never rendered or got enforced.
  - Private Research Projects' required-field list pointed at National/
    Regional Research Projects' funding-institution field instead of its
    own - could never have been satisfied as written.
  - European Research Projects' overheads formula referenced a variable
    name matching no real field (naming drift).
  - One formula-definition resource was shared verbatim by European and
    Private Research Projects for `project_cbgp_overheads`, but each
    form's own "total overheads" field has a different name - split into
    two per-form formula resources. Side effect: European Research
    Projects now has a genuine two-step calculation chain
    (`total_funding → total_overheads → project_cbgp_overheads`), which
    `form_formulas_spec.rb` exercises directly with no mocking.
  - National/Regional Research Projects' year 1-4 overheads formulas
    referenced over-prefixed variable names matching no real field.
- `form_defaults_spec.rb`: the ontology's last real `local:has-defaults`
  example was removed by Sara's "clean test fields" pass, leaving that
  mechanism with zero live users. Rather than reintroduce a disposable
  sandbox field purely to keep a test anchored to "real" content (which is
  what kept breaking across two ontology restructuring passes), this spec
  now tests the SPARQL query layer against a small synthetic in-memory
  ontology and the application layer against real fields with a stubbed
  default - decoupling it from future ontology churn permanently.

Full suite: 203 examples, 0 failures, stable across multiple random seeds.

## [0.16.0] - 2026-08-25
### Changed
- **Switched from GraphDB to Virtuoso** as the triplestore, both for the
  current-state store and the SCD history store. Trigger: GraphDB's
  free/open tier returned to requiring periodic license re-registration.
  Verified live against a real Virtuoso 07.20 container (write, read-back,
  and history-snapshot round trips) before committing to the switch.
  - Unlike GraphDB (one server process hosting multiple named
    repositories), a single Virtuoso process is one quad store - so the
    current-state and history stores, kept *physically* separate on
    purpose (see `configuration.rb`), are now two separate Virtuoso
    containers/processes rather than two repositories in one GraphDB
    instance. `docker-compose.yml` runs both, each bind-mounted (not a
    named Docker volume) to `./virtuoso-data/{current,history}` so
    `virtuoso.ini` and the data/log files sit together on the host,
    directly accessible without `docker volume inspect`.
  - `GRAPHDB_HOST`/`GRAPHDB_USER`/`GRAPHDB_PASS`/`GRAPHDB_DBNAME`/
    `GRAPHDB_HISTORY` are replaced by `VIRTUOSO_HOST`/`VIRTUOSO_USER`/
    `VIRTUOSO_PASS`/`VIRTUOSO_HISTORY_HOST` (no dbname concept needed -
    each Virtuoso instance's endpoint is a distinct host:port instead).
  - New `lib/virtuoso_update_client.rb` (`CBGP::VirtuosoUpdateClient`):
    Virtuoso's SPARQL Update endpoint (`/sparql-auth`) requires HTTP
    Digest auth and rejects Basic outright (confirmed live; no
    `virtuoso.ini` setting in this build offers a way around it), and the
    `sparql-client` gem has no Digest support - this class covers exactly
    the write path with a small Digest handshake, exposing the same
    `#update`/`#insert_data` shape `DATABASE_UPDATE`/
    `HISTORY_DATABASE_UPDATE` already had. Reads are untouched: plain
    `SPARQL::Client` against Virtuoso's unauthenticated `/sparql` endpoint,
    same as before.
  - Added `net-http-digest_auth` as a dependency.
  - Dropped the `onto:` (Ontotext/GraphDB) SPARQL prefix, declared in every
    query but never actually used in any query body.
- `docs/source/installation.md`/`configuration.md` rewritten for the
  Virtuoso setup (no repository-creation step needed at all now - each
  container already is a store). `docker-compose-graphdb.yml` kept as a
  reference/rollback point for the retired GraphDB setup, not maintained
  going forward. `docs/source/backup_and_migration.md` still describes the
  old GraphDB backup procedure - flagged prominently as stale pending a
  Virtuoso-specific rewrite, rather than left looking authoritative.

## [0.15.0] - 2026-08-17
### Added
- `publication_cbgp_authors` ontology field: an ORCID cross-reference to
  `member` (mirrors `project_pi_orcid`'s `references`/`references-via`/
  `references-label` shape), so publications can finally identify which
  authors are CBGP personnel the same way projects identify their PI.
- `lib/doi_registration_agency.rb`: resolves a DOI's registration agency
  (DataCite/Crossref/etc.) via `doi.org/doiRA/`, ported (not taken on as a
  gem dependency) from `fair_champion_harvester`'s
  `DOI.resolve_doi_to_registration_agency`, used by Community-FAIR-Tests.
- `lib/crossref_parser.rb`: a direct `api.crossref.org` parser, so
  Crossref-registered DOIs no longer have to go via OpenAIRE's aggregation.
- `lib/personnel_matcher.rb`: matches a publication's parsed authors against
  existing `member` records - by exact ORCID, or otherwise by an exact,
  accent-insensitive given+family name match - and records confirmed
  matches' ORCIDs on `publication_cbgp_authors`. Deliberately exact-only,
  never fuzzy: a false positive would misattribute an outside co-author's
  identity to a CBGP member, which is worse than an occasional missed match.
### Changed
- `lib/loaders.rb`'s DOI loader now resolves the registration agency first
  and dispatches straight to `datacite_parser`/`crossref_parser`, falling
  back to `openaire_parser` only when the agency is unknown or the
  preferred parser comes back empty - instead of always trying DataCite
  first and blindly retrying on any error.
### Fixed
- `datacite_parser`/`openaire_parser` parsed each author's ORCID and then
  discarded it, keeping only the bare name string - the ORCID is now
  returned alongside the dataset so it can feed personnel matching.
- `datacite_parser`'s HTTP retry loop retried up to 5 times immediately
  with no backoff on *any* `StandardError`, including permanent failures
  like a bad DOI; capped at 2 attempts.
- `openaire_parser` shadowed its own `doi:` parameter with a re-extraction
  loop that unconditionally raised `TypeError` on real OpenAIRE responses
  (`Array#[]` called with a String key) - removed; the already-known input
  DOI is used directly, like `datacite_parser`/`crossref_parser` already do.
- `openaire_parser`'s `journal`/`title` extraction was missing the `.first`
  its sibling parsers use, so it stored literal `["Journal of Things"]`-style
  bracketed strings instead of the plain value.
### Removed
- `lib/params_parsers.rb`: dead code left over from before the
  `Dataset`/ontology-driven refactor - referenced a `CBGP::Publication`/
  `CBGP::Publication::Author` class pair that no longer exists, and ontology
  field IDs (`newpub2_*`) that only exist in a `_BACKUP2` ontology snapshot,
  not the live one. Nothing in the app called any method in this file.

## [0.14.1] - 2026-07-30
### Added
- A live, working example of `local:has-defaults` in the ontology:
  `project_test_default_field`, a disposable sandbox field (visible, not
  hidden this time) that pre-fills with different text on the Research
  vs. Personnel Project forms. `local:has-defaults` lost its only real
  example when `project_category` was removed in 0.13.0, leaving the
  mechanism entirely undemonstrated in the ontology.
### Fixed
- `docs/source/data_model.md`'s "Worked example" section covered
  `local:requires-field` and `local:has-formulas` but had **zero**
  example of `local:has-defaults` itself, despite that being the section
  the surrounding prose introduced - flagged directly by the user.
  Rewritten (English + Spanish) to walk through all three per-form
  mechanisms with accurate, distinct real fields for each. Also fixed a
  subtler inaccuracy caught in the same pass: the old `has-formulas`
  example queried `project_annual_income` as if it were the calculated
  field, when it's actually the *input* to the real calculated field
  (`project_cbgp_overheads`).

## [0.14.0] - 2026-07-30
### Changed
- Reworked the add/edit form layout to be significantly more compact.
  Root causes fixed rather than papered over:
  - `.question-label`'s left-aligned, zero-margin styling was scoped only
    to the Publications form; every other form's labels fell through to a
    generic centered `H1-H4` rule and the browser's default `<h4>` margin,
    compounding with `.field-row`'s own spacing into rows roughly 3x taller
    than intended. Un-scoped so every form gets the same compact treatment.
  - `_section.erb`/`_questionnaire.erb` padded every section and the end
    of the whole form with seven stacked `<br>` tags - removed; row
    spacing already comes from `.field-row` itself.
  - Removed a dead jsTree CDN theme stylesheet loaded on every page for a
    library nothing in this app actually uses (the tree-select widget is
    fully hand-rolled) - also removed an empty leftover `<style>` block.
### Fixed
- **Data loss bug**: `_textfield.erb`/`_field.erb`/`_smallfield.erb` (the
  widgets behind `honorific_title`, `project_application_reference`,
  `project_call_for_proposal`, `project_end_date_extension`,
  `project_partner_institutions`) rendered an always-empty box regardless
  of the field's actual stored value. Saving *any* edit to a record with
  one of these fields already filled in silently wiped it, since the
  blank-looking box submitted as blank. Fixed by actually displaying the
  current value; the field now correctly round-trips through an edit.
  Found live, root-caused, and fixed in the same session.
- `honorific_title` was mistakenly declared `Multiple`-cardinality in the
  ontology (CBGP-Ontology) even though the widget only ever supported one
  value - corrected to `Single`, matching actual behavior.

## [0.13.1] - 2026-07-29
### Added
- `docs/source/data_model.md` (English + Spanish): a new architecture-
  reference page explaining the two-layer shape every record actually has
  on disk (graph-level metadata - `dcterms:created`/`dcterms:modified`/
  `dcterms:type` - versus the SIO reified-attribute content inside the
  named graph itself), how both connect back to the ontology's Forms/
  Sections/Questions/Answers classes, and worked SPARQL examples for
  writing a raw query against the triple store directly - including the
  non-obvious two-hop indirection `local:has-formulas` and
  `local:has-defaults` both use (Form → an intermediate node → the actual
  field), contrasted with `local:requires-field`'s direct link. Linked
  from [Philosophy & Design](philosophy.md) and the main table of
  contents.

## [0.13.0] - 2026-07-29
### Added
- Every record, on every form, now automatically gets `dcterms:type
  <form-class-uri>` written onto its graph at save time
  (`write_dataset_to_db_query`), stamped from the true form (not the
  shared dbname) - a real Dublin Core term ("the nature or genre of the
  resource"), in the same default-graph provenance slot as the existing
  `dcterms:created`/`dcterms:modified` triples. Display label resolves for
  free from the form class's own existing bilingual `rdfs:label` - no new
  answer-block or ontology configuration needed for this to work on any
  current or future form.
### Removed
- `project_category`, the hand-declared hidden discriminator field
  (shipped in 0.11.0) distinguishing Research vs Personnel Project
  records, is gone - it was deployment-specific and only ever needed as a
  form discriminator, a need the new universal `dcterms:type` stamp
  covers generically for every form, not just these two. Its question
  class, answer-block, both answers, and both `local:has-defaults` nodes
  were removed from the ontology; existing sandbox records were migrated
  by a one-off backfill utility (`utilities/backfill_dcterms_type.rb`).
### Fixed
- The calculated field's live-preview JavaScript only ever worked when a
  calculated field happened to render (by `local:question-order`) after
  every field it depends on - otherwise its dependency-listener setup ran
  before the dependency's own input existed in the DOM and silently never
  attached. Fixed by deferring listener attachment to `DOMContentLoaded`.
- `HiddenField` questions (e.g. the now-removed `project_category`) still
  rendered a label and an empty row on the add/edit form. Now fully
  suppressed in add/edit mode; search mode is unaffected (still the
  filterable dropdown added in 0.12.0).
- Found while investigating the above: `local:has-defaults` is only ever
  applied to a brand-new record (via `new_with_defaults`) - never
  re-applied on edit, so a record that started without a default-derived
  value keeps missing it forever, even across edits. No code change (the
  new `dcterms:type` stamp is unconditional on every write and isn't
  affected by this), but worth documenting as a general gotcha for any
  future use of `local:has-defaults`.

## [0.12.0] - 2026-07-28
### Added
- **Calculated fields**: a form can now declare that one of its fields is
  computed automatically from other field values, rather than typed in by
  the user, via a new `local:has-formulas` ontology branch (Dentaku
  expressions - a safe, sandboxed expression evaluator, not Ruby `eval`).
  Like `local:has-defaults`/`local:requires-field`, this is declared
  per-form: the same shared field can be calculated differently on two
  different forms, or not calculated at all on a form that doesn't declare
  a formula for it.
  - Computation is server-side and authoritative, always run at save time
    from that submission's other field values - nothing a user could type
    or tamper with in a calculated field's own widget (which carries no
    `name` attribute at all) ever reaches the database.
  - **Dependency chains are supported**: one calculated field's formula can
    reference another calculated field's result (e.g. a percentage
    calculated *of* another percentage, rather than of a raw input
    field), resolved automatically via a bounded fixed-point iteration -
    no need to declare fields in dependency order.
  - The widget (`_calculated.erb`) shows a greyed-out, read-only box with
    the formula displayed underneath in plain text, plus a live
    (non-authoritative) preview that recomputes as dependency fields
    change and cascades correctly through a dependency chain.
  - Demonstrated on the Research/Personnel Project forms' `project_overheads`
    ("UPM overheads") / `project_cbgp_overheads` fields (a real two-step
    chain), plus a disposable `project_test_*` sandbox chain for manual
    testing - all percentages are explicitly-marked placeholders pending
    real confirmation from CBGP/UPM administration.
  - Documented (English + Spanish) in the Admin Guide's new "Calculated
    fields" section, including the per-form declaration requirement for
    ontology editors.
### Fixed
- `GET /cbgp/search-dataset/:database` 500'd for any form containing a
  `HiddenField`-widget question (e.g. `project_category`, shipped in
  0.11.0) because no `_search_hiddenfield.erb` partial existed. Added one:
  since a HiddenField is still a genuine controlled-vocabulary field even
  though it's invisible on the add/edit form, search mode now renders it
  as an ordinary dropdown, letting records be filtered by that value.

## [0.11.0] - 2026-07-28
### Added
- Support for multiple ontology **Forms sharing one dbname/graph table**:
  Research Project (`cbgp:project`) and Personnel Project
  (`cbgp:personnel_project`) are now two distinct forms over the same
  `project` table, each showing only its own relevant subset of the shared
  question classes. The Personnel Project field list is a placeholder for
  now, pending curation from the Admin team - this feature exists precisely
  so that curation can happen entirely in the ontology, with no code changes
  required, once they decide what they actually need.
- **Per-form default answers**: a form can now declare a default value for
  one of its fields via a new `local:has-defaults` branch pointing at
  `pre-populated-answer` nodes (`local:default-for-field` +
  `local:default-value`), so the same shared question class can default
  differently depending on which form is used. Used to build a hidden,
  multilingual `project_category` discriminator field (defaults to
  "Research Project" / "Personnel Project" depending on which form created
  the record), so records can be queried by project type without exposing
  the field to the user.
- **Per-form required fields**: a form can now mark one of its fields
  mandatory via a new `local:requires-field` annotation, direct from the
  form class to the question class (no reification needed, unlike
  defaults, since "required" carries no value of its own). Enforced
  server-side before anything is written to the database, reusing the
  existing friendly-error/`ValidationError` machinery, and surfaced to
  users as a bold red asterisk next to the field label on the form.
- `HiddenField`, an existing but previously-unused ontology widget type, is
  now exercised for the first time by the `project_category` field above.
### Fixed
- `GET /cbgp/dataset/:database` (and the equivalent user-facing route) built
  the add/edit questionnaire from the record's shared dbname instead of its
  specific form class, so two forms sharing one dbname would incorrectly
  both render whichever form's fields happened to match the dbname string.
  The admin `POST /cbgp/validate-dataset/:database` route had the same bug
  on the validation-error redisplay path. Both are fixed by threading the
  true form class through as a hidden `form_class` field on submission,
  since the URL alone only ever carries the shared dbname.
- Added `code10`, `consejo`, `genero`, and `cluster` to the members XML
  export (`xmlmembers.erb`), which were missing from the exported fields.

## [0.10.0] - 2026-07-09
### Added
- Full bilingual (English/Spanish) end-user documentation site, built from
  scratch with Sphinx + MyST + sphinx-intl, hosted on Read the Docs
  (`docs/source/`): Philosophy & Design (the ontology-driven/metaprogrammed
  architecture, its novelty relative to Rails/Django scaffolding, CEDAR,
  VIVO, Wikibase, and SHACL+DASH), Installation, Configuration, a five-page
  Admin Guide (data entry, history & snapshots, search & queries, cross-
  references, exports), a User Guide, and a Time Travel / API guide covering
  the history query endpoints shipped in 0.9.0 with real worked examples.
  Every page ships with a complete Spanish translation via `.po` catalogs
  under `docs/source/locale/es/`.
- `docs/source/backup_and_migration.md` (EN+ES): what actually needs backing
  up (only the `cbgp-graphdb` Docker volume and `.env` — everything else is
  reproducible), a self-alerting nightly backup script that captures both a
  native GraphDB backup and a vendor-neutral N-Quads dump of every
  repository (portable to any RDF store, not just GraphDB) and emails an
  alert on failure using the application's own `NOTIFY_*` SMTP settings,
  disaster-recovery restore, and full server-migration steps.
- `.env.example` — a safe, checked-in placeholder template for every `.env`
  variable the application reads, previously undocumented in the repo.
### Fixed
- `docker-compose.yml` was missing several `.env` variables
  (`configuration.rb` aborts startup without them: `NOTIFY_PW`,
  `CBGP_USERS`, `CBGP_SECRET`, `NOTIFY_TO`, `NOTIFY_UN`, `GRAPHDB_DBNAME`,
  `GRAPHDB_HISTORY`) and had a malformed `CBGP_KB` value with a stray
  trailing `#"`. Found while writing the installation documentation, since
  following it as written would otherwise have failed.

## [0.9.0] - 2026-07-09
### Added
- SCD Type 2 history query layer ("time machine"), built on the recording
  mechanism shipped in 0.7.0: `lib/history_queries.rb` provides schema-agnostic
  primitives (never assume a past snapshot's shape matches today's ontology)
  composed into two queries — a record's complete version history resolved by
  an identifying field (e.g. a member's full history by ORCiD, from creation
  to now), and a facet/date-range filtered search across every record of a
  type that's durable across deletions (a deleted record still contributes
  via its last known snapshot, with an optional numeric field summed across
  the matches). Every result is a real `RDF::Repository` (each contributing
  snapshot kept in its own named graph, so same-named fields across different
  versions never collide) served as JSON-LD or TriG.
- Three new read-only API endpoints exposing the above over HTTP, so any
  language/tool can call them directly (not just this app's own views):
  `POST /cbgp/query-history/:database` (duplicates `query-dataset`'s request
  shape — arbitrary facet/date-range params, optional `sum_field` — against
  history instead of current state), `GET /cbgp/history/:database/:questionclass/:value`
  (one record's timeline), and `GET /cbgp/facets/:form_type` (exposes the
  field/controlled-vocabulary metadata already used to render forms, for
  building external query UIs without scraping HTML).
- `utilities/time_machine.rb` CLI (`history`/`funding` subcommands) as a
  quick way to exercise the above without the web app.
### Fixed
- `escape_for_literal` (used to sanitize every field value before writing it
  into a SPARQL string literal) never actually escaped backslashes — its
  `gsub('\\', '\\\\')` was silently a no-op (gsub re-interprets backslash
  sequences in a *string* replacement, so the "doubled" backslash collapsed
  back to a single one). A value containing a literal backslash could produce
  a malformed SPARQL literal and fail to save. Fixed with the block form of
  `gsub`, which isn't subject to that re-interpretation.
### Testing
- New `spec/lib/history_queries_spec.rb` (50 examples) and
  `spec/lib/escape_for_literal_spec.rb` (6 examples, including a real
  round-trip through `RDF::Turtle::Reader`) — full suite now 128 examples.

## [0.8.2] - 2026-07-09
### Fixed
- The 0.8.1 test-count badge never actually worked: it was a shields.io
  "endpoint" badge, which requires shields.io's servers to anonymously fetch
  `badges/tests.json` from this repo - impossible for a private repo (the
  fetch 404s for anyone who isn't an authenticated viewer, which is exactly
  who shields.io is). Replaced with a shields.io *static* badge, where the
  count is baked directly into the badge's own image URL instead of being
  fetched from anywhere, so it renders the same regardless of repo
  visibility. CI now rewrites that URL directly in `README.md` (and
  `badges/tests.json` is gone).

## [0.8.1] - 2026-07-09
### Added
- Second README badge showing the actual RSpec pass count (e.g. "72
  passing"), not just a generic pass/fail indicator. CI parses the RSpec
  JSON formatter's summary counts after each run on the default branch and
  commits a small `badges/tests.json` (shields.io "endpoint" format), which
  the README badge reads via `img.shields.io/endpoint`. Turns red with an
  "X/Y passing" message instead of green if any examples fail.

## [0.8.0] - 2026-07-09
### Added
- GitHub Actions CI (`.github/workflows/rspec.yml`) runs the RSpec suite on
  every push and pull request; status badge added to the README.
- RSpec regression coverage asserting every free-text search field emits an
  accent-insensitive filter, and that all six monetary project fields stay
  tagged `currency`.
### Fixed
- Accent-insensitive search had stopped matching accented values (e.g.
  searching "Maria" found none of the many accented "María" records) for
  most fields, including member name/surname. It was gated per field on an
  `ACCENT_SENSITIVE_LABELS` allowlist keyed on the ontology's human-readable
  label text, which had drifted out of sync three ways: `member_name`/
  `member_surnames` were never added; label rewording silently broke
  exact-string matches already in the list (`"affiliation"` vs. the live
  `"Affiliations"`, `"partner institutions"` vs. the live `"Partner
  institutions (acronym and country)"`); and the list was English-only, so
  it silently stopped applying under the Spanish UI too. Accent-insensitive
  matching is now unconditional for every free-text/dropdown search field,
  so there's no longer a label list to fall out of sync.
- `project_overheads` was left tagged as a plain string field instead of
  `currency` (unlike its five sibling monetary fields), so it silently
  skipped locale-aware validation, display formatting, and search
  normalization.
### Changed
- The RSpec suite's ontology source (`spec/spec_helper.rb`) now prefers a
  sibling `../CBGP-Ontology` checkout, then a live fetch from
  `https://w3id.org/CBGP-App`, before falling back to the committed
  `spec/fixtures/cbgp-application-ontology.owl` snapshot. The
  previously-frozen-only fixture is exactly what let the
  `project_overheads` mistagging above go undetected by tests.

## [0.7.0] - 2026-07-07
### Added
- SCD Type 2 history tracking (recording layer only — query/reporting layer
  and UI are designed but not yet built; see `.claude/plans/enumerated-zooming-sedgewick.md`).
  Every edit or delete of a record now snapshots its full prior state into a
  separate, dedicated GraphDB repository (`kbhistory`, new `GRAPHDB_HISTORY`/
  `HISTORY_USER`/`HISTORY_PASS` config) before the current-state graph is
  dropped/rewritten. Current-state data and behavior are completely
  unchanged — snapshots are annotated at the graph level (nanopub/PROV
  style: `prov:generatedAtTime`, `prov:invalidatedAtTime`,
  `local:history-reason`, `local:history-detail`) rather than mixed into the
  record's own data, and include a heuristic human-readable summary of what
  changed (e.g. "Total funding: 15,000.00 → 20,000.00").
- Fixed a pre-existing bug found while building the above: `dcterms:created`
  was silently lost after a record's first edit (an edit's cleanup deleted
  it and nothing rewrote it) — it's now preserved across edits.

## [0.6.0] - 2026-07-06
### Added
- Currency field type: a new `currency` ontology widget/object-class that
  stores amounts in a canonical decimal form and displays/parses them in the
  current UI language's number convention (e.g. `1,234.56` in English,
  `1.234,56` in Spanish). Applied to Project total funding.
- Mouseover help: field labels show a tooltip sourced from the ontology's
  `rdfs:comment`, when the ontology provides one, via the same bilingual
  mechanism already used for labels.
- Email notifications to admins whenever a User submits a UserFacing form
  (e.g. a new Project application), listing whichever fields were actually
  filled in. SMTP settings (host, port, TLS, auth, from address, recipients)
  are now configured via `.env` instead of hardcoded, and `NOTIFY_TO` accepts
  a comma-separated list of recipients.
- Friendly form-validation errors: an invalid field value (e.g. a bad
  currency amount) now redisplays the form with a clear error banner and the
  user's original input intact, instead of crashing with a raw exception
  page — including on the public User-facing form.
- RSpec test suite, fully offline (a frozen local snapshot of the ontology,
  no live GraphDB dependency), covering currency parsing/formatting, form
  validation-error handling, and controlled-vocabulary label resolution.
- Submit button duplicated at both top and bottom of the search and
  bulk-publication-upload forms, matching the existing add/edit forms.
### Fixed
- Multi-word accent-insensitive search (e.g. a title search containing a
  space) no longer crashes with a SPARQL lexical error.
- Search results (both the on-screen table and the Excel/TSV export) now
  show the proper language-aware label for controlled-vocabulary fields
  (select/radio/tree-selector) instead of the raw internal ontology class ID.
- `coerce_value` no longer mutates its `klass` argument in place (was
  crashing with `FrozenError` on frozen string input).
- `GET /cbgp/refresh` now actually refreshes: it previously only reloaded
  the in-memory ontology but left the per-form-type field caches stale, so
  ontology edits (e.g. marking another field as currency) silently didn't
  take effect until the whole app process was restarted.
- Fixed a crash (`NoMethodError` on `nil.capitalize`) when a User's project
  submission failed validation: the user-facing validate route never set
  `@database`, which only mattered once a validation error started
  re-rendering the form instead of the thank-you page.
- Fixed the User project form redisplaying with the *full Admin field set*
  after a validation error, instead of the restricted set of fields Users
  are actually meant to see/fill in. The route only ever had the dbname
  (e.g. `"project"`) available from the URL, not the restricted UserFacing
  questionnaire code (e.g. `"userproject"`) — a pre-existing ambiguity that
  never mattered while a failed submission just crashed, but silently built
  the wrong (Admin) questionnaire once redisplay started working. The
  correct form code is now carried through via a hidden field.
- Fixed currency validation silently accepting malformed amounts (e.g.
  `"2,00.0000"` was misread as `200.00`) by blindly stripping whatever
  character looked like a thousands separator and handing the rest to a
  float parser. Amounts are now checked against the actual expected shape
  (proper 3-digit grouping, at most 2 decimal digits) before being accepted,
  in both English and Spanish conventions.

## [0.5.0] - 2026-04-23
### Added
- Foreign-key cross-reference typeahead: fields can now search-by-label on
  another form and store a different field's value (e.g. type a member's
  surname, store their ORCiD).
- Typeahead extended to work on plain (non cross-reference) fields too.
### Removed
- Bulk delete capability (removed in favor of more deliberate per-record
  deletion after the foreign-key work made bulk deletes riskier).

## [0.4.0] - 2026-02-23 to 2026-03-05
### Added
- XML export endpoints (`/cbgp/active-members`, `/cbgp/active-emails`) feeding
  an external pipeline.
- Dataset purge utility/script.
### Fixed
- Query fixes uncovered while building the exports.

## [0.3.0] - 2026-02-02 to 2026-02-08
### Added
- Bulk loader for member/personnel records.
- Multi-instance tree-selector widget (works with more than one tree selector
  per questionnaire).
### Changed
- Performance optimization: batched SPARQL queries instead of per-record
  round-trips.
- Pinned Ruby to 3.2.4 for deployment compatibility.

## [0.2.0] - 2025-12-29 to 2025-12-30
### Added
- Bulk delete capability for search results (explicit commit: "version
  0.2.0.with bulk delete").
### Fixed
- Various bug fixes; tree display now works together with search.

## [0.0.7] - 2025-12-19 to 2025-12-29
### Added
- Public/user-facing forms distinct from the admin interface; role-based
  (admin vs. user) access control.
- Bulk publication loader with duplicate detection based on existing external
  identifiers (DOIs).
### Changed
- Refactored permanent identifiers and named-graph handling so edits reuse
  the existing graph URI instead of creating duplicates.
- Search results can now be edited directly and downloaded to Excel.

## [0.0.6] - 2025-09-30 to 2025-10-27
### Added
- Tree-selector (hierarchical) widget for controlled vocabularies.
- Search-dataset forms (query by field, paginated results).
- STATUS, FPI, partner-institution, and call-for-proposal fields.
### Fixed
- Multi-value ("Multiple" cardinality) field handling across load/search/save.

## [0.0.5] - 2025-08-15 to 2025-09-15
### Added
- Staff/personnel database and its ontology-driven form.
- Countries controlled-vocabulary list.
- Spanish translation; multilingual (en/es) rendering throughout.
- All three databases (staff, project, publication) rendering end-to-end for
  the first time.

## [0.0.4] - 2025-05-07 to 2025-05-27
### Added
- Full DataCite/OpenAIRE citation lookup and preformatted citation box.
### Changed
- Dockerized the app.
- More resilient DataCite API calls; basic date sanity checks; fixed SASS
  (Compass) stylesheet compilation.
- Docker image tagged `v0.0.3` at this point.

## [0.0.2] - 2025-01-27 to 2025-03-19
### Added
- First ontology-driven database portal: forms, fields, and widgets generated
  at runtime from the OWL knowledgebase instead of being hand-coded.
- Read/write to the triple store (SPARQL) with round-trip record editing.
- Author/affiliation list widgets for publications.
- Semantic data models (drawio diagrams) for staff, project, and publications.

## [0.0.1] - 2024-12-20 to 2025-01-08
### Added
- Initial commit; first exploratory Project and Staff data models.
- Raw HTML form prototypes and CSV-based data capture, pre-ontology.

[Unreleased]: https://github.com/CBGP-UPM-INIA-PUBLIC/CBGP-Databases/compare/v0.9.0...HEAD
[0.9.0]: https://github.com/CBGP-UPM-INIA-PUBLIC/CBGP-Databases/compare/v0.8.2...v0.9.0
[0.8.2]: https://github.com/CBGP-UPM-INIA-PUBLIC/CBGP-Databases/compare/v0.8.1...v0.8.2
[0.8.1]: https://github.com/CBGP-UPM-INIA-PUBLIC/CBGP-Databases/compare/v0.8.0...v0.8.1
[0.8.0]: https://github.com/CBGP-UPM-INIA-PUBLIC/CBGP-Databases/compare/v0.7.0...v0.8.0
[0.7.0]: https://github.com/CBGP-UPM-INIA-PUBLIC/CBGP-Databases/compare/v0.6.0...v0.7.0
[0.6.0]: https://github.com/CBGP-UPM-INIA-PUBLIC/CBGP-Databases/compare/v0.5.0...v0.6.0
[0.5.0]: https://github.com/CBGP-UPM-INIA-PUBLIC/CBGP-Databases/commits/main
