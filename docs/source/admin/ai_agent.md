# Asking questions through an AI agent

The application can be questioned by an AI agent, in plain language, instead of
through the search pages: "how many members are active?", "who is funded by this
project?", "show me a timeline of this person's funding". The agent only *reads*
the same records the search pages show. It cannot add, change or delete anything.

This is built on the Model Context Protocol (MCP), so any agent that speaks it
can be connected. Nothing in it is specific to this institute: what the agent
knows about the data comes from the ontology, exactly like the rest of the
application.

## Connecting an agent

The address is the application's own address followed by `/mcp`, for example
`https://staff.admin.cbgp.upm.es/mcp`. It accepts `POST` requests only, and every
request must carry the `Authorization: Bearer <token>` header, with the token set
as `MCP_TOKEN` (see [Configuration](../configuration.md#ai-agent-access-mcp)).
Until `MCP_TOKEN` is set the endpoint is switched off.

For an agent that is configured with a file, the entry looks like this (this
example is for Hermes; other agents use the same two pieces of information):

```yaml
mcp_servers:
  cbgp:
    url: "https://staff.admin.cbgp.upm.es/mcp"
    headers:
      Authorization: "Bearer ${CBGP_MCP_TOKEN}"
```

Keep the name short. Agents usually put it in front of every tool's name, and some
model providers limit how long a tool name may be.

To check the connection from the server, before involving the agent:

```bash
curl -s -X POST https://your-host/mcp \
  -H "Authorization: Bearer $MCP_TOKEN" -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}'
```

A list of tools means it works. A `401` means the token is wrong, and a message
saying MCP is disabled means `MCP_TOKEN` is not set in the running container.

## What the agent can do

| Tool | What it is for |
|---|---|
| `describe_form` | What data exists: the forms, and the fields of each one |
| `search_records` | Find records by text, exact value or date; also counts ("how many") |
| `get_record` | One record in full, with cross-references shown as names |
| `linked_records` | Follow relationships: a person's projects, commitments and publications; a project's people |
| `record_history` | How one record changed over time, field by field |
| `aggregate` | Count or add up records by category and by calendar year (headcount at year end, funding per year, papers per year) |
| `chart_over_time` | Draw how a number changes over the years, split by category |
| `chart_breakdown` | Draw what a number is made up of, by category |
| `render_timeline` | Draw a timeline of dated facts the agent gathered |

The agent is told to use these before searching the web for anything about the
institute's own people, projects, publications or funding, and to say which source
each figure came from. It works from what is in the database: if the records are
incomplete, so is the answer, and a good agent says so.

Only the staff-facing forms are offered. Forms that members use to submit
information are not, because nobody queries them.

## Describing your data for the agent

An agent chooses its tools by reading short descriptions, so it needs to know what
the data *is*, and which everyday words mean which form (an agent asked about
"employees" has to work out that they are in the Member form). That text is written
in the ontology, in the same place and the same way as the forms' names, in **both
languages**:

- one `rdfs:comment` on the `cbgp:forms` class says what the whole dataset is;
- one `rdfs:comment` on each form says what its records are.

```xml
<owl:Class rdf:about="https://w3id.org/CBGP-App#member">
    <rdfs:subClassOf rdf:resource="https://w3id.org/CBGP-App#forms"/>
    <rdfs:comment xml:lang="en">People who work or study at the institute: employees,
      staff, researchers, students and visitors, one record per person. The status field
      says whether a person is currently Active, Inactive or Historical; the current staff
      are those with status Active.</rdfs:comment>
    <rdfs:comment xml:lang="es">Personas que trabajan o estudian en el instituto: ...</rdfs:comment>
    <rdfs:label xml:lang="en">Member</rdfs:label>
    ...
```

Write the **first sentence** so that it stands alone: it is the only part shown in the
agent's one-line list of forms. Say what the records are and use the words people
use for them. Put the detail in the sentences after it, and the agent sees those
when it asks about that form. If something has a precise definition (such as "current
staff"), state it here: the agent will not guess it.

`check_ontology.rb` warns about any form, or the dataset itself, that has no
description in a language, so a form added later cannot go without one. A change
shows up for the agent after `/cbgp/refresh`, with no restart.

## Charts

Two tools draw charts, and the agent picks one by the question being asked:

- **`chart_over_time`** answers "how has X changed over the years, by category?": headcount at the end of each year,
  funding per year by source, papers per year. Bars, stacked bars, 100% bars (shares), lines or areas.
- **`chart_breakdown`** answers "what is X made up of?": gender balance by category, funding mix, members by nationality.

You do not give the tool numbers. You give it the *question* (which records, what to count or add up, how to split
them, how the years are laid out) and the server computes the numbers and draws the chart, so no figure is ever
retyped by a language model and the same question always gives the same chart. Each chart carries a **caption**
saying what was asked, as of what date, how many records were read and how many were left out for lacking a needed
field (for example members without a start date). A chart pasted into a report can be rebuilt next year from its caption.

Every chart is drawn in two shapes from the same data, sized so the finished image has exactly that proportion, title and
caption included: a wide **slide** (16:9) and a **report** column (3:2) for a Word document. By default the agent hands the
chart over as a **PNG image** in the shape asked for (ask for "the report shape" for a Word column), which you download like
any picture; an image is also the cheapest way to deliver a chart (see below). If you want the interactive page instead, ask
for it: it shows one shape, and under it are links to download **both** as SVG (a vector file that opens in any drawing or
slide program) and as PNG, and the **numbers** behind the chart as a tab-separated file that opens in Excel. The page's own
PNG link appears only where the page is allowed to run its small script: in a saved copy of the page, or one opened on its
own, but not inside a chat window that blocks scripts.

The same applies to **timelines**: bars for things with a start and an end, a diamond for a single date, a bar that runs on
to today for something still going, a dashed line marking today, rows grouped into labelled bands.

Making a PNG on the server needs the `rsvg-convert` program and a font. The supplied Docker image includes both
(`librsvg2-bin` and `fonts-dejavu-core`); on a server without them the chart quietly comes as the interactive page instead.

## Branding the charts

Colours, font and a footer line come from a small file, not from the code and not from the ontology. Copy
`theme/theme.example.yml` to `theme/theme.yml`, edit it, and the next chart drawn uses it, with no restart. In Docker the
compose file mounts the folder (`./theme:/server/theme:ro`); another location can be named with `CBGP_THEME_FILE`.

```yaml
name: CBGP
font: Calibri, Carlito, "DejaVu Sans", Arial, sans-serif
colors: { background: "#ffffff", text: "#262626", muted: "#666666", band: "#f2f5f2", grid: "#dfe5df", highlight: "#c0392b" }
series: ["#007336", "#c58b00", "#2a78b5", "#68af27", "#4c4c4c", "#b5532a", "#8a5ab5", "#2a9fa6"]
categories: { European: "#2a78b5" }
footer: "Source: CBGP administrative database"
```

- **`series`** are the colours of the categories of a chart, in order (up to 24). The default starts with CBGP green
  (`#007336`, `#68af27` and the charcoal `#4c4c4c` were sampled from the CBGP logo), then colours chosen to stay apart from
  the greens and from each other, also for colour-blind readers: eight categories cannot all be green.
- **`categories`** fixes the colour of a named category, wherever it appears, so "European" is the same colour in every
  chart. The name ignores case and accents.
- **`colors`** are the page colours; `dark` takes the same keys for a viewer whose system is in dark mode (a dark brand
  colour is lightened automatically on a dark page, so it does not vanish). Text on a coloured bar is white or near-black,
  whichever reads better on that colour.
- **`footer`** is printed under every chart, and inside the downloaded SVG and PNG.

The file is untrusted text that ends up inside pictures, so every value is checked: colours must be `#rgb` or `#rrggbb`,
the font a plain list of names. A value that is missing or wrong is replaced by the built-in default for that value, and
logged once, so a typo can never stop a chart from being drawn.

## What the tools cost

The agent is billed by the amount of text it reads, so each tool has a cost, and there are two kinds. The figures below are
measured on this build by `ruby utilities/mcp_cost_report.rb` (add `--markdown` for tables like these); tokens are estimated
as characters divided by four, which is rough, so read them as **relative sizes**.

**Fixed cost.** The definition of every tool (name, description, parameters) is sent to the model with *every* request it
makes, and answering one question takes several requests. Adding a tool therefore makes every question dearer, whether or
not that tool is used. This is why the descriptions are kept short and why a new tool has to earn its place.

| Tool | Tokens (approx.) |
|---|---|
| aggregate | ~1350 |
| search_records | ~1330 |
| chart_over_time | ~1230 |
| chart_breakdown | ~1090 |
| render_timeline | ~700 |
| describe_form | ~450 |
| linked_records | ~420 |
| record_history | ~340 |
| get_record | ~270 |
| all tools together | ~7190 |

**Cost per call.** A call returns a short text for the model (a few hundred tokens at most). A chart or timeline can also return a *page*. Some agent programs keep that page in the conversation and send it again with every later request, so a page can be the largest cost of a conversation about a chart; an image attachment, by contrast, is kept as a file and the model reads only its name, which is why a PNG image is the default. The middle column is what a page would cost if it were passed on. A page is about four times the size of one picture, because it carries the picture and downloadable copies of both shapes.

| Call | Text the model reads | Page (if the client passes it on) | One SVG file |
|---|---|---|---|
| any chart as a PNG attachment (the default) | ~150 | - (a file; the model reads only its name) | - |
| chart_over_time, bars, 12 years, 1 series | ~120 | ~4770 | ~1140 |
| chart_over_time, lines, 12 years, 2 series | ~140 | ~5540 | ~1340 |
| chart_over_time, stacked, 12 years, 2 series | ~140 | ~7750 | ~1950 |
| chart_over_time, stacked, 12 years, 8 series | ~280 | ~20130 | ~5270 |
| chart_over_time, stacked, 30 years, 4 series | ~310 | ~17290 | ~4490 |
| chart_breakdown, bars, 12 categories | ~140 | ~5300 | ~1280 |
| chart_breakdown, shares, 12 categories x 2 series | ~160 | ~7690 | ~1920 |
| render_timeline, 7 rows | ~80 | ~2590 | - |

What drives the cost, in order: the **number of categories** (series) in a chart, then the number of points on the axis, then the
kind of chart (bars are the cheapest, lines a little more, stacked charts the most). A PNG attachment is an image and costs
as one. To keep costs down: ask for fewer categories (`top_n` merges the smallest into "Other"), keep charts as image attachments
rather than interactive pages unless the page is needed, and do not add a tool for something an existing one can already do.

## Languages

Questions can be asked in English or Spanish. A value can be named in either: a
category called "Catedrático" and one called "Full professor" are the same value to
the agent. Dates can be written as `today` or `hoy`.

## Good to know

- The agent is a language model: it can misread a question. Counts and lists come
  from the database, but which records it decides to count is its own judgement,
  which is why the descriptions above state definitions such as "current staff".
- The application does not store what an agent asks. Its log records only which
  tool ran and how long it took (and, if something breaks inside the server, the
  error itself), never the question or the answer, since both can contain personal
  data. The agent program may keep its own conversation history; that is outside this
  application.
- The same records are reachable through the search pages, so the agent shows nothing
  that a logged-in administrator cannot already see.
