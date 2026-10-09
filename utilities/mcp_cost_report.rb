#!/usr/bin/env ruby
# frozen_string_literal: true

# What the AI-agent tools cost, in tokens, on THIS build - so the figures in the documentation (and any
# decision to add or trim a tool) rest on a measurement, not a guess.
#
#   ruby utilities/mcp_cost_report.rb            # plain text
#   ruby utilities/mcp_cost_report.rb --markdown # tables to paste into the docs
#   (add --verbose to see the application's own log lines)
#
# Two kinds of cost:
#   * FIXED: every tool's definition (name, description, parameters) is sent to the model with every request it
#     makes, several times for one question. Adding a tool raises the cost of EVERY question.
#   * PER CALL: what one call returns - a short text for the model, and for a chart a page. Whether a client
#     passes the page on to the model, or only shows it to the person, depends on the client; the page figures
#     are what it would cost if it did.
#
# Tokens are estimated as characters / 4, a rough rule for English and Spanish text and for markup; a real
# tokenizer differs by tens of percent, so read the figures as relative sizes. Needs the ontology (CBGP_KB) but no
# database: sample charts are drawn from made-up numbers.

ENV['CBGP_KB'] ||= File.expand_path('../../CBGP-Ontology/cbgp-application-ontology.owl', __dir__)
ENV['CBGP_THEME_FILE'] ||= File.join(__dir__, 'no-such-theme.yml') # the built-in theme, so the figures do not depend on a local file
ENV['CBGP_USERS'] ||= '{"x":{"password":"x","role":"user"}}'
ENV['CBGP_SECRET'] ||= 'x' * 64
require_relative '../app/controllers/application_controller'

$stderr.reopen(File::NULL) unless ARGV.include?('--verbose') # the application is chatty on stderr
MARKDOWN = ARGV.include?('--markdown')

def tokens(chars) = (chars / 4.0).round(-1).to_i.clamp(10, Float::INFINITY)

def table(title, header, rows)
  puts "\n#{MARKDOWN ? '###' : '=='} #{title}"
  if MARKDOWN
    puts "| #{header.join(' | ')} |", "|#{header.map { '---' }.join('|')}|"
    rows.each { |r| puts "| #{r.join(' | ')} |" }
  else
    widths = header.each_index.map { |i| ([header[i]] + rows.map { |r| r[i] }).map { |c| c.to_s.length }.max }
    puts header.each_with_index.map { |h, i| h.to_s.ljust(widths[i]) }.join('  ')
    rows.each { |r| puts r.each_with_index.map { |c, i| c.to_s.ljust(widths[i]) }.join('  ') }
  end
end

# --- fixed cost ---------------------------------------------------------------------------------
tools = Mcp::Tool.registry.reject { |t| t.tool_name.to_s.end_with?('_for_spec') }
fixed = tools.map { |t| [t.tool_name, JSON.generate(t.definition).length] }.sort_by { |_, n| -n }
table('Fixed cost: tool definitions, sent with every request', ['Tool', 'Tokens (approx.)'],
      fixed.map { |name, n| [name, "~#{tokens(n)}"] } + [['all tools together', "~#{tokens(fixed.sum { |_, n| n })}"]])

# --- per call: charts ---------------------------------------------------------------------------
words = Mcp::Widgets::Chart::WORDS['en']
def synthetic(points:, series:, years: true)
  x = years ? (2015...(2015 + points)).map(&:to_s) : (1..points).map { |i| "Category #{i}" }
  Mcp::Widgets::Chart::Table.new(x_labels: x, series: (1..series).map { |s| { label: "Series #{s}", values: x.each_index.map { |i| 5.0 + ((i * 7 + s * 13) % 40) } } })
end

samples = [
  ['chart_over_time, bars, 12 years, 1 series', 12, 1, 'bar', true],
  ['chart_over_time, lines, 12 years, 2 series', 12, 2, 'line', true],
  ['chart_over_time, stacked, 12 years, 2 series', 12, 2, 'stacked', true],
  ['chart_over_time, stacked, 12 years, 8 series', 12, 8, 'stacked', true],
  ['chart_over_time, stacked, 30 years, 4 series', 30, 4, 'stacked', true],
  ['chart_breakdown, bars, 12 categories', 12, 1, 'bar', false],
  ['chart_breakdown, shares, 12 categories x 2 series', 12, 2, 'percent', false]
]
rows = samples.map do |label, points, series, style, years|
  tbl = synthetic(points: points, series: series, years: years)
  out = Mcp::Widgets::Chart.render(table: tbl, style: style, title: 'Sample chart', y_label: 'Records', notes: ['Count of records by category; data as of today.'])
  text = JSON.generate(x: tbl.x_labels, series: tbl.series.map { |s| { label: s[:label], values: s[:values] } }, style: style, note: 'x' * 260)
  [label, "~#{tokens(text.length)}", "~#{tokens(out[:html].length)}", "~#{tokens(out[:svg].length)}"]
end
rows.unshift(['any chart as a PNG attachment (the default)', "~#{tokens(JSON.generate(x: Array.new(12, 'x'), series: [{ label: 'Series', values: Array.new(12, 1.0) }], note: 'x' * 430).length)}", '- (a file; the model reads only its name)', '-'])
rows << ['render_timeline, 7 rows', "~#{tokens(300)}",
         "~#{tokens(Mcp::Widgets::Timeline.render(rows: (2020..2026).map { |y| { 'label' => "Project #{y}", 'start' => "#{y}-01-01", 'end' => "#{y}-12-31", 'lane' => 'Funding' } })[:html].length)}", '-']
table('Per call: what one chart costs', ['Call', 'Text the model reads', 'Page (if the client passes it on)', 'One SVG file'], rows)

puts "\nA PNG attachment is kept by the agent program as a file: the model reads its name, not its bytes." unless MARKDOWN
puts "\nTokens are characters / 4 (a rough rule); see the notes at the top of this file." unless MARKDOWN
